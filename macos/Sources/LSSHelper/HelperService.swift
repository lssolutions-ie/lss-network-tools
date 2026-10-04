import Foundation
import LSSCore
import LSSXPC
import os

/// The listener delegate and the shared state of the helper (contract §4).
///
/// XPC delivers messages on its own queues, several at a time. The mutable state — the
/// child table, the connection count and the idle-exit generation — is guarded by `lock`;
/// everything else is immutable after `init`. That is what makes the
/// `@unchecked Sendable` sound.
///
/// The helper never reads the app's Defaults, never trusts a path from the app (every
/// path goes through `RequestValidator`) and never executes anything but the validated
/// executable.
final class HelperService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    /// An on-demand daemon exits when nobody uses it; launchd starts it again on the next
    /// connection (which also picks up a rebuilt binary).
    static let idleExitDelay: TimeInterval = 60
    /// Upper bound on concurrent runs (the app runs one at a time).
    static let maximumConcurrentRuns = 4

    let validator: RequestValidator
    let callerValidation: CallerValidation
    let logger = Logger(subsystem: LSSHelperCodeIdentifier, category: "service")

    private struct Entry {
        let ownerUID: uid_t
        let sessionID: ObjectIdentifier
        /// nil between the reservation and the spawn.
        var process: ChildProcess?
        /// A cancel (or disconnect) that arrived before the spawn; honoured by `attach`.
        var cancelRequested = false
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var connectionCount = 0
    private var idleGeneration = 0

    init(validator: RequestValidator = RequestValidator(), callerValidation: CallerValidation = CallerValidation()) {
        self.validator = validator
        self.callerValidation = callerValidation
        super.init()
    }

    /// Called once from `main.swift` after the listener resumed.
    func start() {
        callerValidation.logMode()
        logger.notice("LSSHelper \(LSSHelperBuildVersion, privacy: .public) (protocol \(LSSHelperProtocolVersion)) listening on \(LSSHelperMachServiceName, privacy: .public)")
        scheduleIdleExit()
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard callerValidation.accept(connection) else { return false }
        let session = HelperSession(service: self, callerUID: connection.effectiveUserIdentifier)
        connection.exportedInterface = NSXPCInterface(with: LSSHelperProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak self, weak session] in
            if let session { self?.sessionEnded(session) }
            self?.connectionClosed()
        }
        lock.withLock {
            connectionCount += 1
            idleGeneration += 1
        }
        connection.resume()
        return true
    }

    // MARK: Child table

    /// Reserves `token` for a new run; false when it is in use or too many runs are active.
    func reserve(token: String, ownerUID: uid_t, session: HelperSession) -> Bool {
        lock.withLock {
            guard entries[token] == nil, entries.count < Self.maximumConcurrentRuns else { return false }
            entries[token] = Entry(ownerUID: ownerUID, sessionID: ObjectIdentifier(session), process: nil)
            idleGeneration += 1
            return true
        }
    }

    func attach(_ process: ChildProcess, to token: String) {
        let cancelled: Bool = lock.withLock {
            entries[token]?.process = process
            return entries[token]?.cancelRequested ?? false
        }
        if cancelled {
            logger.notice("cancel arrived before the spawn; terminating pid \(process.pid)")
            process.terminate()
        }
    }

    func release(token: String) {
        lock.withLock { _ = entries.removeValue(forKey: token) }
        scheduleIdleExit()
    }

    /// SIGTERM → SIGKILL for the run with `token`, if `uid` started it. A run that is
    /// still being validated or staged is marked and stopped as soon as it spawns.
    func terminate(token: String, requestedBy uid: uid_t) -> Bool {
        let found: (exists: Bool, process: ChildProcess?) = lock.withLock {
            guard entries[token] != nil, entries[token]?.ownerUID == uid else { return (false, nil) }
            entries[token]?.cancelRequested = true
            return (true, entries[token]?.process)
        }
        guard found.exists else { return false }
        if let process = found.process {
            logger.notice("cancel requested for pid \(process.pid)")
            process.terminate()
        }
        return true
    }

    /// The app went away (quit, crash): stop the runs it started, as the pty path does
    /// when its terminal closes.
    private func sessionEnded(_ session: HelperSession) {
        let id = ObjectIdentifier(session)
        let orphans: [ChildProcess] = lock.withLock {
            var processes: [ChildProcess] = []
            for (token, entry) in entries where entry.sessionID == id {
                entries[token]?.cancelRequested = true
                if let process = entry.process { processes.append(process) }
            }
            return processes
        }
        for process in orphans {
            logger.notice("client disconnected; terminating pid \(process.pid)")
            process.terminate()
        }
    }

    private func connectionClosed() {
        lock.withLock { connectionCount = max(0, connectionCount - 1) }
        scheduleIdleExit()
    }

    private func scheduleIdleExit() {
        let generation: Int? = lock.withLock {
            guard connectionCount == 0, entries.isEmpty else { return nil }
            idleGeneration += 1
            return idleGeneration
        }
        guard let generation else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.idleExitDelay) { [weak self] in
            guard let self else { return }
            let idle = self.lock.withLock { self.connectionCount == 0 && self.entries.isEmpty && self.idleGeneration == generation }
            if idle {
                self.logger.notice("idle for \(Int(Self.idleExitDelay)) s; exiting (launchd restarts the helper on demand)")
                exit(0)
            }
        }
    }
}

/// The object exported to one accepted connection. Holds the caller's uid (from the
/// connection's audit token at accept time) so no method ever trusts a uid sent by the
/// app. Immutable apart from what `HelperService` guards, hence `@unchecked Sendable`.
final class HelperSession: NSObject, LSSHelperProtocol, @unchecked Sendable {
    private unowned let service: HelperService
    let callerUID: uid_t

    init(service: HelperService, callerUID: uid_t) {
        self.service = service
        self.callerUID = callerUID
    }

    private var logger: Logger { service.logger }

    func run(request: Data, output: FileHandle, reply: @escaping @Sendable (Int32, String?) -> Void) {
        // The received descriptor belongs to this method: closed on every path, right
        // after the spawn on success so EOF reaches the app when the child exits.
        func refuse(_ reason: String, code: String) {
            try? output.close()
            logger.error("run refused (\(code, privacy: .public)): \(reason, privacy: .private)")
            reply(-1, reason)
        }

        guard request.count < RequestValidator.maximumRequestSize else {
            return refuse(RequestValidator.Refusal.requestTooLarge.description, code: "requestTooLarge")
        }
        guard let decoded = try? JSONDecoder().decode(HelperRunRequest.self, from: request),
              RequestValidator.isValidToken(decoded.token) else {
            return refuse(RequestValidator.Refusal.malformedRequest.description, code: "malformedRequest")
        }
        let validated: RequestValidator.Validated
        do {
            validated = try service.validator.validate(decoded, callerUID: callerUID)
        } catch let refusal as RequestValidator.Refusal {
            return refuse(refusal.description, code: refusal.code)
        } catch {
            return refuse(String(describing: error), code: "error")
        }
        guard service.reserve(token: decoded.token, ownerUID: callerUID, session: self) else {
            return refuse("Another run with this token is active, or too many runs are in progress.", code: "busy")
        }

        var arguments = validated.arguments
        var staged: StagedScanFile?
        if let index = arguments.firstIndex(of: "--wifi-scan-json"), index + 1 < arguments.count {
            do {
                let copy = try ScanFileStager.stage(arguments[index + 1], ownerUID: callerUID)
                arguments[index + 1] = copy.path
                staged = copy
            } catch {
                service.release(token: decoded.token)
                return refuse(String(describing: error), code: "scanFile")
            }
        }

        let process: ChildProcess
        do {
            process = try ChildProcess.spawn(
                executable: validated.executable,
                arguments: arguments,
                environment: validated.environment,
                outputDescriptor: output.fileDescriptor
            )
        } catch {
            staged?.remove()
            service.release(token: decoded.token)
            return refuse("The command-line tool could not be started: \(error)", code: "spawn")
        }
        try? output.close()
        service.attach(process, to: decoded.token)
        logger.notice("started pid \(process.pid) for uid \(self.callerUID): \(validated.executable, privacy: .public) \(validated.arguments.first ?? "", privacy: .public) \(validated.arguments.dropFirst().first ?? "", privacy: .public)")

        let token = decoded.token
        let service = self.service
        let waiterLogger = self.logger
        let stagedCopy = staged
        let waiter = Thread {
            let code = process.waitForExit()
            stagedCopy?.remove()
            service.release(token: token)
            waiterLogger.notice("pid \(process.pid) exited with \(code)")
            reply(code, nil)
        }
        waiter.name = "LSSHelper child \(process.pid)"
        waiter.start()
    }

    func cancel(token: String, reply: @escaping @Sendable (Bool) -> Void) {
        reply(service.terminate(token: token, requestedBy: callerUID))
    }

    func repairRunPermissions(runDirectory: String, reply: @escaping @Sendable (Int32, String?) -> Void) {
        do {
            let directory = try service.validator.validateRepair(runDirectory: runDirectory)
            let changed = try PermissionRepair.repair(directory: directory)
            logger.notice("repaired permissions of \(changed) file(s) in \(directory, privacy: .private)")
            reply(changed, nil)
        } catch let refusal as RequestValidator.Refusal {
            logger.error("repair refused (\(refusal.code, privacy: .public))")
            reply(-1, refusal.description)
        } catch {
            logger.error("repair failed: \(String(describing: error), privacy: .public)")
            reply(-1, String(describing: error))
        }
    }

    func version(reply: @escaping @Sendable (String, Int) -> Void) {
        reply(LSSHelperBuildVersion, LSSHelperProtocolVersion)
    }
}

extension RequestValidator {
    /// The contract's entry point (§3): the uid comes from the connection, never from
    /// `request.callerUID`.
    func validate(_ request: HelperRunRequest, callerUID: uid_t) throws -> Validated {
        try validate(arguments: request.arguments, sshPassword: request.sshPassword, callerUID: callerUID)
    }
}
