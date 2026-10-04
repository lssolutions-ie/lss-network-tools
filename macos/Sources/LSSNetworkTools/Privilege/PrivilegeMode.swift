import Defaults

/// How runs get root (PLAN §8.1–§8.2). The helper path is used only while the
/// helper is enabled and answers `version()` with this app's protocol; otherwise a
/// run falls back to sudo in the terminal pane whatever this says.
enum PrivilegeMode: String, CaseIterable, Identifiable, Sendable, Defaults.Serializable {
    /// The SMAppService LaunchDaemon (no password).
    case helper
    /// `sudo <wrapper> …` in the embedded terminal; the password is typed there.
    case sudoTerminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .helper: "Privileged helper (no password)"
        case .sudoTerminal: "sudo in the terminal pane"
        }
    }
}

extension Defaults.Keys {
    /// `.sudoTerminal` until the helper has been verified on this Mac.
    static let privilegeMode = Key<PrivilegeMode>("privilegeMode", default: .sudoTerminal)
}
