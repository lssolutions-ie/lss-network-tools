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
    /// Upper bound per connecting user within that: one run plus one cancel-and-restart
    /// overlap is all a single app ever needs.
    static let maximumRunsPerCaller = 2

    let validator: RequestValidator
    let callerValidation: CallerValidation
    /// Admin-group rule for the connecting uid; `AdminGroupMembership.check(uid:)` in
    /// the daemon. Injectable so an out-of-process probe can show a non-member refused.
    let membershipCheck: @Sendable (uid_t) -> AdminGroupMembership.Outcome
    /// Replaces `callerValidation.accept` when set — only by a probe talking to an
    /// anonymous listener, where there is no signed app to validate. `main.swift`
    /// never sets it.
    let acceptCallerOverride: (@Sendable (NSXPCConnection) -> Bool)?
    let logger = Logger(subsystem: LSSHelperCodeIdentifier, category: "service")

    private struct Entry {
        let ownerUID: uid_t
        let sessionID: ObjectIdentifier
        /// nil between the reservation and the spawn.
        var process: ChildProcess?
        /// A cancel (or disconnect) that arrived before the spawn; honoured by `attach`.
        var cancelRequested = false
    }

    /// A `cancel` that arrived for a token the table does not know yet: the run is
    /// still being validated or its authorization verified. Honoured by `reserve`
    /// (the run is then refused with the `cancelled` code and nothing spawns). Bounded
    /// per uid like the table itself; dropped when that user's connection ends.
    private struct PendingCancel {
        let token: String
        let uid: uid_t
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var pendingCancels: [PendingCancel] = []
    private var connectionCount = 0
    private var idleGeneration = 0

    enum ReserveOutcome {
        case reserved
        /// The token is in use, or too many runs are active (in total, or for this user).
        case busy
        /// `cancel(token:)` for this token arrived before the run got here.
        case cancelled
    }

    init(validator: RequestValidator = RequestValidator(),
         callerValidation: CallerValidation = CallerValidation(),
         membershipCheck: @escaping @Sendable (uid_t) -> AdminGroupMembership.Outcome = { AdminGroupMembership.check(uid: $0) },
         acceptCallerOverride: (@Sendable (NSXPCConnection) -> Bool)? = nil) {
        self.validator = validator
        self.callerValidation = callerValidation
        self.membershipCheck = membershipCheck
        self.acceptCallerOverride = acceptCallerOverride
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
        guard acceptCallerOverride?(connection) ?? callerValidation.accept(connection) else { return false }
        // sudo's rule (`%admin ALL=(ALL) ALL`): only administrators get root from the
        // helper. The uid comes from the connection (audit token), never from a message.
        let callerUID = connection.effectiveUserIdentifier
        switch membershipCheck(callerUID) {
        case .member:
            break
        case .notMember:
            logger.error("rejecting pid \(connection.processIdentifier): uid \(callerUID) is not a member of the admin group (gid \(AdminGroupMembership.adminGroupID))")
            return false
        case .failed(let reason):
            logger.error("rejecting pid \(connection.processIdentifier): admin membership of uid \(callerUID) could not be determined (\(reason, privacy: .public)); failing closed")
            return false
        }
        let session = HelperSession(service: self, callerUID: callerUID)
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

    /// Reserves `token` for a new run. A cancel recorded for it beforehand wins, and is
    /// consumed under the same lock so no cancel can fall between the two checks.
    func reserve(token: String, ownerUID: uid_t, session: HelperSession) -> ReserveOutcome {
        lock.withLock {
            if let index = pendingCancels.firstIndex(where: { $0.token == token && $0.uid == ownerUID }) {
                pendingCancels.remove(at: index)
                return .cancelled
            }
            guard entries[token] == nil, entries.count < Self.maximumConcurrentRuns,
                  entries.values.filter({ $0.ownerUID == ownerUID }).count < Self.maximumRunsPerCaller else { return .busy }
            entries[token] = Entry(ownerUID: ownerUID, sessionID: ObjectIdentifier(session), process: nil)
            idleGeneration += 1
            return .reserved
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
    /// reserved but not yet spawned is marked and stopped as soon as it spawns. A token
    /// the table does not know yet — the run is still in validation or the
    /// authorization check — is recorded for `uid`, and `reserve` refuses it; only a
    /// token owned by another user is answered false.
    func terminate(token: String, requestedBy uid: uid_t) -> Bool {
        enum Found { case running(ChildProcess?), recorded, otherOwner }
        let found: Found = lock.withLock {
            if let entry = entries[token] {
                guard entry.ownerUID == uid else { return .otherOwner }
                entries[token]?.cancelRequested = true
                return .running(entry.process)
            }
            pendingCancels.removeAll { $0.token == token && $0.uid == uid }
            // Bounded like the table: a flood of cancels from one uid drops its oldest.
            while pendingCancels.filter({ $0.uid == uid }).count >= Self.maximumRunsPerCaller,
                  let oldest = pendingCancels.firstIndex(where: { $0.uid == uid }) {
                pendingCancels.remove(at: oldest)
            }
            pendingCancels.append(PendingCancel(token: token, uid: uid))
            return .recorded
        }
        switch found {
        case .otherOwner:
            return false
        case .recorded:
            logger.notice("cancel recorded for uid \(uid) before the run was reserved")
            return true
        case .running(let process):
            if let process {
                logger.notice("cancel requested for pid \(process.pid)")
                process.terminate()
            }
            return true
        }
    }

    /// The app went away (quit, crash): stop the runs it started, as the pty path does
    /// when its terminal closes.
    private func sessionEnded(_ session: HelperSession) {
        let id = ObjectIdentifier(session)
        let uid = session.callerUID
        let orphans: [ChildProcess] = lock.withLock {
            var processes: [ChildProcess] = []
            for (token, entry) in entries where entry.sessionID == id {
                entries[token]?.cancelRequested = true
                if let process = entry.process { processes.append(process) }
            }
            pendingCancels.removeAll { $0.uid == uid }
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
        // Only the refusal code is logged: the reason can quote request values, and the
        // log never carries argv values, the SSH password, the progress token or the
        // authorization blob. Every refusal replies a `HelperRefusal` JSON document.
        func refuse(_ reason: String, code: String) {
            try? output.close()
            logger.error("run refused for uid \(self.callerUID) (\(code, privacy: .public))")
            reply(-1, HelperRefusal(code: code, message: reason).encoded())
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

        // The tool-chain gate (S1–S3, S6): the verdict is this process's own, made just
        // now; the app's view of it only decided whether to show the dialog first.
        switch validated.toolchain {
        case .trusted:
            break
        case .unusable(let refusal):
            // `validate` throws this under both policies; kept exhaustive and closed.
            return refuse(refusal.description, code: refusal.code)
        case .untrusted(let refusal):
            guard let authorization = decoded.authorization, HelperAuthorization.isWellFormed(externalForm: authorization),
                  let right = decoded.authorizationRight, HelperAuthorization.rights.contains(right) else {
                return refuse(refusal.description, code: HelperRefusal.authorizationRequiredCode)
            }
            if !AuthorizationGate.allRightsInstalled {
                AuthorizationGate.ensureRights(logger: logger)
                guard AuthorizationGate.allRightsInstalled else {
                    return refuse("The helper could not install its authorization rights in the policy database; use “sudo in the terminal pane”.",
                                  code: HelperRefusal.authorizationUnavailableCode)
                }
            }
            switch AuthorizationGate.verify(externalForm: authorization, right: right) {
            case .success(let right):
                var offending = "tool chain"
                if case .untrustedToolchain(let tool, let path, let reason) = refusal {
                    offending = "\(tool): \(path) \(reason)"
                }
                // The dialog accepts any administrator's credentials, so the credential
                // may belong to another admin account than the connecting uid.
                logger.notice("run for uid \(self.callerUID) authorised by an administrator credential for right \(right, privacy: .public); running a user-owned tool chain (\(offending, privacy: .public))")
            case .failure(let failure):
                let detail: String
                switch failure {
                case .malformed: detail = "malformed external form"
                case .unknownRight: detail = "unknown right name"
                case .rightsMissing: detail = "rights missing from the policy database"
                case .notAuthorized(let status): detail = "AuthorizationCopyRights status \(status) for right \(right)"
                }
                logger.error("authorization check failed for uid \(self.callerUID): \(detail, privacy: .public)")
                return refuse(refusal.description, code: HelperRefusal.authorizationRequiredCode)
            }
        }

        switch service.reserve(token: decoded.token, ownerUID: callerUID, session: self) {
        case .reserved:
            break
        case .busy:
            return refuse("Another run with this token is active, or too many runs are in progress.", code: "busy")
        case .cancelled:
            return refuse("The run was cancelled before it started.", code: HelperRefusal.cancelledCode)
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
        // Flag names and counts only — never a value.
        let flags = validated.arguments.filter(RequestValidator.acceptedFlags.contains).joined(separator: " ")
        let secrets = RequestValidator.secretEnvironmentKeys.filter { validated.environment[$0] != nil }.sorted().joined(separator: " ")
        logger.notice("started pid \(process.pid) for uid \(self.callerUID): \(validated.executable, privacy: .public), \(validated.arguments.count) argument(s) [\(flags, privacy: .public)], environment secrets [\(secrets, privacy: .public)]")

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

    func toolchainTrust(reply: @escaping @Sendable (String, String?) -> Void) {
        switch service.validator.toolchainVerdict() {
        case .trusted: reply(HelperToolchainVerdict.trusted.rawValue, nil)
        case .untrusted(let refusal): reply(HelperToolchainVerdict.authorizationRequired.rawValue, refusal.description)
        case .unusable(let refusal): reply(HelperToolchainVerdict.unusable.rawValue, refusal.description)
        }
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
    /// `request.callerUID`. The tool chain is *reported*, not refused: `HelperSession.run`
    /// turns an untrusted verdict into the authentication requirement (§11.2).
    func validate(_ request: HelperRunRequest, callerUID: uid_t) throws -> Validated {
        try validate(arguments: request.arguments, sshPassword: request.sshPassword,
                     progressToken: request.progressToken, callerUID: callerUID, toolchainPolicy: .report)
    }
}
