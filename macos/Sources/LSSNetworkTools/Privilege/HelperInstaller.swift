import Foundation
import Observation
import ServiceManagement

/// Registers the privileged helper with launchd through SMAppService
/// (`Contents/Library/LaunchDaemons/ie.lssolutions.lss-network-tools.helper.plist`).
///
/// Registration of a daemon needs an administrator's approval in System Settings →
/// General → Login Items & Extensions. Observed on macOS 27 with an ad-hoc build:
/// before the first registration the status is `.notFound`; `register()` then throws
/// "Operation not permitted" (SMAppServiceErrorDomain 1) yet records the daemon, and
/// the status becomes `.requiresApproval` — that combination is reported as
/// `.needsApproval`, not as a failure.
@MainActor
@Observable
final class HelperInstaller {
    static let plistName = "ie.lssolutions.lss-network-tools.helper.plist"

    enum RegisterOutcome: Equatable {
        case enabled
        /// Recorded by macOS, waiting for approval in Login Items. `thrown` is the
        /// error register() reported anyway, verbatim.
        case needsApproval(thrown: String?)
        case failed(String)
    }

    @ObservationIgnored private let service = SMAppService.daemon(plistName: HelperInstaller.plistName)

    private(set) var status: SMAppService.Status
    /// The last real register/unregister failure, verbatim (description, domain, code).
    private(set) var lastError: String?

    init() {
        status = service.status
    }

    func refresh() {
        status = service.status
    }

    /// `SMAppService.register()` once.
    @discardableResult
    func register() -> RegisterOutcome {
        var thrown: String?
        do {
            try service.register()
        } catch {
            thrown = Self.describe(error)
        }
        refresh()
        switch status {
        case .enabled:
            lastError = nil
            return .enabled
        case .requiresApproval:
            lastError = nil
            return .needsApproval(thrown: thrown)
        default:
            let message = thrown ?? "register() returned without error but the status is \(Self.name(for: status))"
            lastError = message
            return .failed(message)
        }
    }

    /// `SMAppService.unregister()`; false (with `lastError`) when it throws.
    @discardableResult
    func unregister() -> Bool {
        defer { refresh() }
        do {
            try service.unregister()
            lastError = nil
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var statusText: String { Self.text(for: status) }

    static func text(for status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "Not registered"
        case .enabled: "Enabled"
        case .requiresApproval: "Waiting for approval in System Settings → General → Login Items & Extensions"
        case .notFound: "Not registered yet (macOS reports “not found” until the helper is registered from this copy of the app)"
        @unknown default: "Unknown status (\(status.rawValue))"
        }
    }

    /// Short machine-style name for logs and `--helper-status`.
    static func name(for status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }

    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }
}
