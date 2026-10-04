import Defaults

/// How runs get root (PLAN §8.1–§8.2). The helper path is used only while the
/// helper is enabled and answers `version()` with this app's protocol; otherwise a
/// run falls back to sudo in the terminal pane whatever this says.
enum PrivilegeMode: String, CaseIterable, Identifiable, Sendable, Defaults.Serializable {
    /// The SMAppService LaunchDaemon: no password on a root-owned tool chain, the
    /// standard administrator-authentication dialog on a user-owned one (§11.2).
    case helper
    /// `sudo <wrapper> …` in the embedded terminal; the password is typed there.
    case sudoTerminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .helper: "Privileged helper"
        case .sudoTerminal: "sudo in the terminal pane"
        }
    }
}

extension Defaults.Keys {
    /// `.sudoTerminal` until the helper has been verified on this Mac.
    static let privilegeMode = Key<PrivilegeMode>("privilegeMode", default: .sudoTerminal)
    /// How often the helper route asks for administrator authentication on a
    /// user-owned tool chain; five minutes is what sudo does.
    static let helperAuthenticationCadence = Key<AuthorizationSession.Cadence>("helperAuthenticationCadence", default: .fiveMinutes)
}
