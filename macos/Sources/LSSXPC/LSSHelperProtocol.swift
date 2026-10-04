import Foundation

/// Mach service name of the privileged helper (LaunchDaemon registered with SMAppService).
public let LSSHelperMachServiceName = "ie.lssolutions.lss-network-tools.helper"

/// Bumped whenever the protocol below changes incompatibly; the app refuses a mismatch.
public let LSSHelperProtocolVersion = 1

/// Helper build version reported by `version(reply:)`. Kept equal to `macos/VERSION`
/// by hand (the integrator bumps both): the helper must not read it from the app's
/// Info.plist, which it does not trust.
public let LSSHelperBuildVersion = "0.4.0"

/// Bundle identifier of the app allowed to talk to the helper.
public let LSSAppBundleIdentifier = "ie.lssolutions.lss-network-tools"

/// Code-signing identifier of the helper executable (`scripts/sign.sh --identifier`).
public let LSSHelperCodeIdentifier = "ie.lssolutions.lss-network-tools.helper"

/// The XPC interface exported by `LSSHelper` (contract: docs/research/07-m4-privilege-updates-contract.md §2).
///
/// The helper never trusts paths or executables from the app: `run` only ever
/// starts the installed CLI named in `/usr/local/share/lss-network-tools/install.env`
/// with an allow-listed argv (`RequestValidator`).
@objc public protocol LSSHelperProtocol {
    /// Runs the CLI with an allow-listed argv. `request` is JSON of `HelperRunRequest`.
    /// The helper dup2s `output` onto the child's stdout and stderr (one stream, like
    /// the pty path), closes its own copy, and replies when the child exits.
    /// `refusal` is non-nil when the validator rejected the request (nothing ran;
    /// `exitCode` is then -1). A child killed by a signal reports 128 + signal.
    func run(request: Data, output: FileHandle, reply: @escaping @Sendable (Int32, String?) -> Void)

    /// SIGTERM (then SIGKILL after 5 s) to the child started by the run with this token.
    /// Replies false when no such run exists or it belongs to another user.
    func cancel(token: String, reply: @escaping @Sendable (Bool) -> Void)

    /// `chmod 0644` on regular `*.json` files directly inside one run directory under
    /// `DATA_ROOT/output` (repairs the 0600 stress files of old runs). Replies with the
    /// number of files whose mode changed, or -1 and the reason.
    func repairRunPermissions(runDirectory: String, reply: @escaping @Sendable (Int32, String?) -> Void)

    /// Helper build version (`LSSHelperBuildVersion`) and `LSSHelperProtocolVersion`.
    func version(reply: @escaping @Sendable (String, Int) -> Void)
}

/// One run request, serialised as JSON for `LSSHelperProtocol.run`.
public struct HelperRunRequest: Codable, Sendable, Hashable {
    /// UUID chosen by the app; `cancel(token:)` refers to it.
    public var token: String
    /// argv AFTER the executable — exactly `ArgumentBuilder`'s output.
    public var arguments: [String]
    /// Placed in the child's environment as `LSS_SSH_PASSWORD` only; never argv.
    public var sshPassword: String?
    /// Informational; the helper derives the caller from the connection's audit token.
    public var callerUID: UInt32?

    public init(token: String = UUID().uuidString, arguments: [String], sshPassword: String? = nil, callerUID: UInt32? = nil) {
        self.token = token
        self.arguments = arguments
        self.sshPassword = sshPassword
        self.callerUID = callerUID
    }
}

/// Code-signing requirement strings used on both ends of the XPC connection.
///
/// With a Team ID (Developer ID builds) each side requires the other to be signed by
/// the same team. Ad-hoc builds have no Team ID, so the requirement degrades to the
/// code identifier, which the helper strengthens with the cdhash of the app bundle it
/// is installed in (anyone can ad-hoc sign a binary with our identifier; nobody can
/// forge a cdhash). Values are validated before they are interpolated so a requirement
/// string can never be malformed — `setCodeSigningRequirement` raises on a bad one.
public enum LSSCodeRequirement {
    /// `^[A-Z0-9]{10}$` — the form Apple issues.
    public static func isValidTeamIdentifier(_ team: String) -> Bool {
        let scalars = Array(team.unicodeScalars)
        return scalars.count == 10 && scalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// Lower-case hex of a 20-byte (SHA-1 or truncated SHA-256) code-directory hash.
    public static func isValidCDHash(_ hash: String) -> Bool {
        let scalars = Array(hash.unicodeScalars)
        return scalars.count == 40 && scalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// What the helper requires of a connecting app.
    /// * Team ID → `anchor apple generic and identifier "<app>" and certificate leaf[subject.OU] = "<team>"`.
    /// * Ad hoc → `identifier "<app>"`, plus `and cdhash H"<hash>"` when the app's cdhash is known.
    /// Invalid inputs are dropped (an invalid team never widens to the ad-hoc form: it yields nil).
    public static func app(teamIdentifier: String?, cdhash: String?) -> String? {
        if let teamIdentifier {
            guard isValidTeamIdentifier(teamIdentifier) else { return nil }
            return "anchor apple generic and identifier \"\(LSSAppBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }
        var requirement = "identifier \"\(LSSAppBundleIdentifier)\""
        if let cdhash {
            guard isValidCDHash(cdhash) else { return nil }
            requirement += " and cdhash H\"\(cdhash)\""
        }
        return requirement
    }

    /// What the app requires of the helper it connects to.
    public static func helper(teamIdentifier: String?) -> String? {
        if let teamIdentifier {
            guard isValidTeamIdentifier(teamIdentifier) else { return nil }
            return "anchor apple generic and identifier \"\(LSSHelperCodeIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }
        return "identifier \"\(LSSHelperCodeIdentifier)\""
    }
}
