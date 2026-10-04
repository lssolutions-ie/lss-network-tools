import Foundation
import Observation
import Security
import Defaults
import LSSXPC

/// The app's administrator credential for helper runs on a user-owned tool chain
/// (contract §11.2, S5).
///
/// The app never sees or stores a password: Authorization Services shows the standard
/// macOS dialog (Touch ID where SecurityAgent offers it) and keeps the credential inside
/// securityd, bound to this process's `AuthorizationRef`. What the helper receives is the
/// ref's 32-byte external form plus the name of the right it was obtained for, which the
/// helper verifies without any dialog of its own. At most one ref is held; `lock()`
/// destroys it and its credential (`kAuthorizationFlagDestroyRights`).
///
/// Cadence (`Cadence`): every run makes a fresh ref (the dialog shows each time, and
/// `RunCoordinator` locks as soon as the request is answered); five minutes keeps one
/// ref on the 300 s right, so the policy database re-prompts after that; once per
/// session keeps one ref on the session right until quit or Lock now.
///
/// Concurrency: at most one acquisition is in flight. The blocking
/// `AuthorizationCopyRights` runs in a detached task on the ref, so nothing may free
/// that ref until the task has returned — `externalForm` throws `.busy` instead of
/// starting a second acquisition, and `lock()` during one only records the request;
/// the free happens in `externalForm`'s continuation, after the task has returned.
@MainActor
@Observable
final class AuthorizationSession {
    enum Cadence: String, CaseIterable, Identifiable, Sendable, Defaults.Serializable {
        case everyRun
        case fiveMinutes
        case session

        var id: String { rawValue }

        var title: String {
            switch self {
            case .everyRun: "Every run"
            case .fiveMinutes: "Every five minutes (like sudo)"
            case .session: "Once per app session"
            }
        }

        /// The policy-database right whose timeout implements this cadence. Sent with
        /// the request (`HelperRunRequest.authorizationRight`): the helper verifies
        /// exactly this right, so its `timeout` is the bound the helper enforces.
        var right: String {
            switch self {
            case .everyRun, .fiveMinutes: HelperAuthorization.fiveMinuteRight
            case .session: HelperAuthorization.sessionRight
            }
        }
    }

    enum AuthorizationError: LocalizedError, Equatable {
        /// The user dismissed the dialog (`errAuthorizationCanceled`), or the run was
        /// cancelled (or the session locked) while the dialog was up.
        case cancelled
        /// Any other non-zero `OSStatus` from Authorization Services.
        case failed(OSStatus)
        /// Another authentication is in flight — its dialog is still on screen.
        case busy

        var errorDescription: String? {
            switch self {
            case .cancelled: "Administrator authentication was cancelled."
            case .failed(let status): "Authorization Services returned status \(status)."
            case .busy: "An administrator-authentication dialog is already open; answer or dismiss it first."
            }
        }
    }

    /// Holds the `AuthorizationRef` (an `OpaquePointer`, which Swift 6 does not treat as
    /// `Sendable`) so the blocking `AuthorizationCopyRights` can run in a detached task
    /// instead of freezing the main thread while the dialog is up. Sound because the
    /// pointer is immutable after `init`, securityd serialises calls on one ref, at most
    /// one acquisition is in flight on it (`externalForm` throws `.busy` otherwise), and
    /// the session never calls `AuthorizationFree` while that acquisition is outstanding:
    /// `lock()` then only sets `lockRequested`, and the free runs in `externalForm` once
    /// the detached task has returned.
    private final class ReferenceBox: @unchecked Sendable {
        let reference: AuthorizationRef

        init(_ reference: AuthorizationRef) {
            self.reference = reference
        }
    }

    /// What `acquire` returns: the external form, and whether the dialog was shown (as
    /// opposed to a credential the ref still held being applied silently).
    private struct Acquired: Sendable {
        let form: Data
        let dialogShown: Bool
    }

    /// `kAuthorizationEnvironmentPrompt`: the line SecurityAgent shows above the
    /// credential fields, under the right's own description.
    nonisolated static let prompt = "The network audit runs as root with tools installed under your user account."

    @ObservationIgnored private var box: ReferenceBox?
    /// The acquisition in flight, if any (`isAuthenticating` mirrors it for the UI).
    @ObservationIgnored private var inFlight: Task<Result<Acquired, AuthorizationError>, Never>?
    /// `lock()` was called while an acquisition was in flight; honoured when it returns.
    @ObservationIgnored private var lockRequested = false
    /// When the dialog was last answered (not when the credential was last used).
    private(set) var authenticatedAt: Date?
    /// The right the held credential was obtained for (nil when none is held).
    private(set) var heldRight: String?
    /// True while an acquisition is in flight (the dialog may be up).
    private(set) var isAuthenticating = false

    var isAuthenticated: Bool { heldRight != nil }

    /// The external form to send with a helper run (together with `cadence.right`),
    /// prompting the user only when the held credential does not cover that right or
    /// has expired — a silent `AuthorizationCopyRights` is tried first, so a cached
    /// credential never moves `authenticatedAt`. Runs the blocking calls off the main
    /// actor. Throws `.busy` while another acquisition is in flight.
    func externalForm(for cadence: Cadence) async throws -> Data {
        // Single flight: a second request while the dialog is up must neither start a
        // second AuthorizationCopyRights on the ref nor free it (lock) underneath.
        guard inFlight == nil else { throw AuthorizationError.busy }
        if cadence == .everyRun || (heldRight != nil && heldRight != cadence.right) {
            lock()
        }
        let box: ReferenceBox
        if let existing = self.box {
            box = existing
        } else {
            var reference: AuthorizationRef?
            let status = AuthorizationCreate(nil, nil, [], &reference)
            guard status == errAuthorizationSuccess, let reference else { throw AuthorizationError.failed(status) }
            box = ReferenceBox(reference)
            self.box = box
        }
        let right = cadence.right
        let task = Task.detached(priority: .userInitiated) {
            Self.acquire(right, on: box)
        }
        inFlight = task
        isAuthenticating = true
        let result = await task.value
        // Back on the main actor with the task returned: the only point at which the
        // ref may be freed again.
        inFlight = nil
        isAuthenticating = false
        if lockRequested {
            // Locked (run cancelled, Lock now, Unregister, cadence change) while the
            // dialog was up: the credential it produced is destroyed, not kept.
            lockRequested = false
            free()
            throw AuthorizationError.cancelled
        }
        switch result {
        case .success(let acquired):
            if acquired.dialogShown || authenticatedAt == nil { authenticatedAt = .now }
            heldRight = right
            return acquired.form
        case .failure(let error):
            lock()
            throw error
        }
    }

    /// Destroys the credential and the ref (`kAuthorizationFlagDestroyRights`): the next
    /// run on a user-owned tool chain shows the dialog again. While an acquisition is
    /// in flight the free is deferred to `externalForm`'s continuation (the detached
    /// task may be inside `AuthorizationCopyRights` on this very ref), which then
    /// reports the acquisition as cancelled; the UI state clears immediately.
    func lock() {
        authenticatedAt = nil
        heldRight = nil
        if inFlight != nil {
            lockRequested = true
            return
        }
        free()
    }

    /// `AuthorizationFree(…, [.destroyRights])` on the held ref. Only called with no
    /// acquisition in flight.
    private func free() {
        if let box {
            _ = AuthorizationFree(box.reference, [.destroyRights])
        }
        box = nil
    }

    /// Blocking. First without interaction — a credential the ref still holds (the
    /// five-minute right within 300 s, the session right) is applied silently and the
    /// dialog is not shown; any other status leads to the interactive call, whose own
    /// status is the one reported (`errAuthorizationCanceled` → `.cancelled`).
    nonisolated private static func acquire(_ right: String, on box: ReferenceBox) -> Result<Acquired, AuthorizationError> {
        var dialogShown = false
        if copyRights(right, on: box, flags: [.extendRights]) != errAuthorizationSuccess {
            dialogShown = true
            let status = copyRights(right, on: box, flags: [.interactionAllowed, .extendRights, .preAuthorize])
            switch status {
            case errAuthorizationSuccess: break
            case errAuthorizationCanceled: return .failure(.cancelled)
            default: return .failure(.failed(status))
            }
        }
        var form = AuthorizationExternalForm()
        let made = AuthorizationMakeExternalForm(box.reference, &form)
        guard made == errAuthorizationSuccess else { return .failure(.failed(made)) }
        return .success(Acquired(form: withUnsafeBytes(of: &form) { Data($0) }, dialogShown: dialogShown))
    }

    /// One `AuthorizationCopyRights` for `right` with the prompt environment. Every C
    /// string lives inside its `withCString` for the whole call; the prompt's
    /// `valueLength` is its UTF-8 byte count.
    nonisolated private static func copyRights(_ right: String, on box: ReferenceBox, flags: AuthorizationFlags) -> OSStatus {
        right.withCString { rightName in
            kAuthorizationEnvironmentPrompt.withCString { promptName in
                prompt.withCString { promptText in
                    var rightItem = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(name: promptName, valueLength: prompt.utf8.count,
                                                       value: UnsafeMutableRawPointer(mutating: promptText), flags: 0)
                    return withUnsafeMutablePointer(to: &rightItem) { rightPointer in
                        withUnsafeMutablePointer(to: &promptItem) { promptPointer in
                            var rights = AuthorizationRights(count: 1, items: rightPointer)
                            var environment = AuthorizationEnvironment(count: 1, items: promptPointer)
                            return AuthorizationCopyRights(box.reference, &rights, &environment, flags, nil)
                        }
                    }
                }
            }
        }
    }
}
