import Foundation
import Observation
import Security
import LSSXPC

/// The app's end of the XPC connection to the privileged helper
/// (`NSXPCConnection(machServiceName:options: .privileged)`).
///
/// One connection is kept for the app's lifetime and re-created after invalidation.
/// The app requires the helper to carry the helper's code identifier (and, in a
/// Developer ID build, this app's Team ID); the helper checks the app in turn. When
/// that requirement cannot be built or parsed the client does not connect at all
/// (`ClientError.untrustedHelperRequirement`).
///
/// Nothing here is logged: requests carry the SSH password and the progress token.
@MainActor
@Observable
final class HelperClient {
    enum ClientError: LocalizedError, Equatable {
        /// The connection failed: the helper is not registered/approved, crashed, or
        /// refused this process (wrong signature, or a non-administrator account —
        /// the helper invalidates such connections without a reply, so the two look
        /// alike from here).
        case connection(String)
        case timedOut
        /// The helper's validator or file checks refused the request.
        case refused(String)
        /// This app could not build or parse the code-signing requirement the helper
        /// must satisfy; connecting without one would accept any process on the Mach
        /// service name, so nothing is attempted.
        case untrustedHelperRequirement(String)

        var errorDescription: String? {
            switch self {
            case .connection(let message):
                "The privileged helper is not reachable: \(message). \(AdminGroupMembership.refusalExplanation) It must also be registered and approved in System Settings → General → Login Items & Extensions."
            case .timedOut: "The privileged helper did not answer in time."
            case .refused(let reason): "The privileged helper refused the request: \(reason)"
            case .untrustedHelperRequirement(let detail):
                "The app cannot verify the privileged helper's code signature (\(detail)), so it will not connect to it. Use “sudo in the terminal pane” in Settings → Privileges."
            }
        }
    }

    struct VersionInfo: Equatable, Sendable {
        let version: String
        let protocolVersion: Int
        var isCompatible: Bool { protocolVersion == LSSHelperProtocolVersion }
    }

    enum RunOutcome: Equatable, Sendable {
        /// The child's exit code (128 + signal when it was killed).
        case exited(Int32)
        /// Nothing ran.
        case refused(String)
    }

    static let versionTimeout: TimeInterval = 3
    static let repairTimeout: TimeInterval = 15
    /// After the helper replied, how long to wait for the last output bytes (EOF).
    static let drainTimeout: TimeInterval = 2

    /// This app's Team ID (nil for ad-hoc builds).
    nonisolated static let ownTeamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    @ObservationIgnored private var connection: NSXPCConnection?

    // MARK: Calls

    /// The helper's build version and protocol version.
    func version() async throws -> VersionInfo {
        let connection = try currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                box.resume(throwing: ClientError.connection(error.localizedDescription))
            }) as? LSSHelperProtocol else {
                box.resume(throwing: ClientError.connection("the connection returned no proxy"))
                return
            }
            proxy.version { version, protocolVersion in
                box.resume(returning: VersionInfo(version: version, protocolVersion: protocolVersion))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.versionTimeout) {
                box.resume(throwing: ClientError.timedOut)
            }
        }
    }

    /// Runs one request. The helper writes the child's stdout and stderr into a pipe
    /// whose bytes reach `onOutput` on the main actor, in order; the call returns when
    /// the child has exited and its output is drained.
    func run(_ request: HelperRunRequest, onOutput: @escaping @MainActor @Sendable (Data) -> Void) async throws -> RunOutcome {
        let payload = try JSONEncoder().encode(request)
        // Before the pipe exists: a connection that cannot be trusted means nothing runs.
        let connection = try currentConnection()
        let pipe = Pipe()
        let pump = OutputPump(readHandle: pipe.fileHandleForReading, onOutput: onOutput)
        pump.start()
        let reply: RunReply
        do {
            reply = try await withCheckedThrowingContinuation { continuation in
                let box = ResumeOnce(continuation)
                let writeHandle = pipe.fileHandleForWriting
                if let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    box.resume(throwing: ClientError.connection(error.localizedDescription))
                }) as? LSSHelperProtocol {
                    proxy.run(request: payload, output: writeHandle) { code, refusal in
                        box.resume(returning: RunReply(code: code, refusal: refusal))
                    }
                } else {
                    box.resume(throwing: ClientError.connection("the connection returned no proxy"))
                }
                // The message carries its own duplicate of the descriptor (taken while the
                // call was encoded); ours must close or the reader never sees EOF.
                try? writeHandle.close()
            }
        } catch {
            await pump.finish(within: Self.drainTimeout)
            throw error
        }
        await pump.finish(within: Self.drainTimeout)
        if let refusal = reply.refusal { return .refused(refusal) }
        return .exited(reply.code)
    }

    /// Asks the helper to stop the run with `token`. False when it is not running or
    /// the helper is unreachable.
    func cancel(token: String) async -> Bool {
        guard let connection = try? currentConnection() else { return false }
        let stopped: Bool? = try? await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                box.resume(throwing: ClientError.connection(error.localizedDescription))
            }) as? LSSHelperProtocol else {
                box.resume(throwing: ClientError.connection("the connection returned no proxy"))
                return
            }
            proxy.cancel(token: token) { box.resume(returning: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.versionTimeout) {
                box.resume(throwing: ClientError.timedOut)
            }
        }
        return stopped ?? false
    }

    /// `chmod 0644` on the run's `*.json` files; returns how many changed.
    func repair(runDirectory: String) async throws -> Int {
        let connection = try currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                box.resume(throwing: ClientError.connection(error.localizedDescription))
            }) as? LSSHelperProtocol else {
                box.resume(throwing: ClientError.connection("the connection returned no proxy"))
                return
            }
            proxy.repairRunPermissions(runDirectory: runDirectory) { changed, refusal in
                if let refusal {
                    box.resume(throwing: ClientError.refused(refusal))
                } else {
                    box.resume(returning: Int(changed))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.repairTimeout) {
                box.resume(throwing: ClientError.timedOut)
            }
        }
    }

    /// Drops the connection (after the helper was unregistered or re-registered).
    func reset() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: Connection

    /// The requirement the helper must satisfy, parsed. Throws instead of degrading:
    /// a connection without a requirement would trust whatever answers on the Mach
    /// service name.
    static func helperRequirement(teamIdentifier: String?) throws -> String {
        guard let requirement = LSSCodeRequirement.helper(teamIdentifier: teamIdentifier) else {
            throw ClientError.untrustedHelperRequirement("this app's Team ID “\(teamIdentifier ?? "")” is not of the form Apple issues")
        }
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, parsed != nil else {
            throw ClientError.untrustedHelperRequirement("the requirement “\(requirement)” does not parse")
        }
        return requirement
    }

    private func currentConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        // Fail closed: no connection at all when the requirement cannot be built or parsed.
        let requirement = try Self.helperRequirement(teamIdentifier: Self.ownTeamIdentifier)
        let connection = NSXPCConnection(machServiceName: LSSHelperMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LSSHelperProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, let current = self.connection, ObjectIdentifier(current) == id else { return }
                self.connection = nil
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}

private struct RunReply: Sendable {
    let code: Int32
    let refusal: String?
}

/// Resumes a continuation at most once: the reply, the error handler and a timeout race.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }
}

/// Reads the helper's output pipe on its own thread and hands each chunk to the main
/// actor through the main queue, so chunks arrive in order and before the completion
/// (which is signalled through the same queue). `finish(within:)` waits for EOF — every
/// writer closed — or gives up after the timeout (a stray process holding the pipe).
///
/// Mutable state (`stopRequested`, `finished`, `waiters`) is guarded by `lock`; the rest
/// is immutable, hence `@unchecked Sendable`.
private final class OutputPump: @unchecked Sendable {
    private let readHandle: FileHandle
    private let onOutput: @MainActor @Sendable (Data) -> Void
    private let lock = NSLock()
    private var stopRequested = false
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(readHandle: FileHandle, onOutput: @escaping @MainActor @Sendable (Data) -> Void) {
        self.readHandle = readHandle
        self.onOutput = onOutput
    }

    func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "LSS helper output"
        thread.start()
    }

    func finish(within timeout: TimeInterval) async {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            lock.withLock { stopRequested = true }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = lock.withLock { () -> Bool in
                if finished { return true }
                waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    private func readLoop() {
        let descriptor = readHandle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while !lock.withLock({ stopRequested }) {
            let ready = poll(&request, 1, 200)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer[0..<count])
                let deliver = onOutput
                DispatchQueue.main.async { MainActor.assumeIsolated { deliver(chunk) } }
            } else if count == 0 {
                break
            } else if errno != EINTR && errno != EAGAIN {
                break
            }
        }
        try? readHandle.close()
        DispatchQueue.main.async { [self] in
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                finished = true
                defer { waiters = [] }
                return waiters
            }
            pending.forEach { $0.resume() }
        }
    }
}
