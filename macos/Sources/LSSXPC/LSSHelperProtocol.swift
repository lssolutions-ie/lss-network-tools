import Foundation

/// Mach service name of the privileged helper (LaunchDaemon registered with SMAppService).
public let LSSHelperMachServiceName = "ie.lssolutions.lss-network-tools.helper"

/// Bumped whenever the protocol below changes incompatibly; the app refuses a mismatch.
/// 2 (GUI 1.0.1): `HelperRunRequest.authorization` + `authorizationRight`,
/// `toolchainTrust(reply:)`, and every `run` refusal reply is a `HelperRefusal` JSON
/// document (`repairRunPermissions` still replies the bare reason).
public let LSSHelperProtocolVersion = 2

/// Helper build version reported by `version(reply:)`. Kept equal to `macos/VERSION`
/// by hand (the integrator bumps both): the helper must not read it from the app's
/// Info.plist, which it does not trust.
public let LSSHelperBuildVersion = "1.0.2"

/// Bundle identifier of the app allowed to talk to the helper.
public let LSSAppBundleIdentifier = "ie.lssolutions.lss-network-tools"

/// Code-signing identifier of the helper executable (`scripts/sign.sh --identifier`).
public let LSSHelperCodeIdentifier = "ie.lssolutions.lss-network-tools.helper"

/// The XPC interface exported by `LSSHelper` (contract: docs/research/07-m4-privilege-updates-contract.md §2).
///
/// The helper never trusts paths or executables from the app: `run` only ever
/// starts the installed CLI named in `/usr/local/share/lss-network-tools/install.env`
/// with an allow-listed argv (`RequestValidator`).
///
/// Tool-chain gate (contract §11.2): a root-owned tool chain runs without a password.
/// When any tool or search-path folder the engine would use as root is writable by a
/// non-root user (`untrustedToolchain`), the helper runs only if the request carries an
/// `AuthorizationExternalForm` whose credential satisfies the one right the request
/// names (`authorizationRight`, one of `HelperAuthorization.rights`) — obtained by the
/// app through the standard macOS administrator-authentication dialog — and refuses
/// with the `authorizationRequired` code otherwise. A missing required tool or a
/// malformed search path is not a trust question: it stays a plain refusal that no
/// authentication clears. `toolchainTrust` tells the app beforehand which case applies.
@objc public protocol LSSHelperProtocol {
    /// Runs the CLI with an allow-listed argv. `request` is JSON of `HelperRunRequest`.
    /// The helper dup2s `output` onto the child's stdout and stderr (one stream, like
    /// the pty path), closes its own copy, and replies when the child exits.
    /// `refusal` is non-nil when the validator rejected the request (nothing ran;
    /// `exitCode` is then -1); it is the JSON of a `HelperRefusal` (code + message).
    /// A child killed by a signal reports 128 + signal.
    func run(request: Data, output: FileHandle, reply: @escaping @Sendable (Int32, String?) -> Void)

    /// The helper's verdict on the tool chain it would run, as a `HelperToolchainVerdict`
    /// raw value: `trusted` (`reason` nil; a run needs no authentication),
    /// `authorizationRequired` (the `untrustedToolchain` description; the helper will
    /// demand `HelperRunRequest.authorization`), or `unusable` (the description of a
    /// refusal no authentication clears — a required tool missing from the root search
    /// path, a relative PATH entry). Advisory for the app; the helper decides again at
    /// request time.
    func toolchainTrust(reply: @escaping @Sendable (String, String?) -> Void)

    /// SIGTERM (then SIGKILL after 5 s) to the child started by the run with this token.
    /// A token the helper does not know yet (the run is still being validated, or its
    /// authorization verified) is remembered for this user, and the run is refused with
    /// the `cancelled` code when it reaches the child table. Replies false only when the
    /// token belongs to another user's run.
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
    /// The app's per-run secret for the progress events (`^[A-Za-z0-9_-]{8,64}$`,
    /// `ProgressLineParser.makeToken()`): placed in the child's environment as
    /// `LSS_PROGRESS_TOKEN`, so the engine writes `@@LSS <token> {…}` and echoed
    /// device text cannot forge an event. Never argv, never logged.
    public var progressToken: String?
    /// Informational; the helper derives the caller from the connection's audit token.
    public var callerUID: UInt32?
    /// The 32-byte `AuthorizationExternalForm` of an `AuthorizationRef` holding an
    /// administrator credential for `authorizationRight`. Required only when the
    /// helper's tool chain is user-owned (`toolchainTrust` → `authorizationRequired`);
    /// the helper verifies it without any dialog of its own and never logs it. Like the
    /// external form itself it is a bearer secret while the credential lives.
    public var authorization: Data?
    /// The right the app authenticated for — one of `HelperAuthorization.rights`
    /// (`AuthorizationSession.Cadence.right`). Credentials are per token, so this name is
    /// what selects the timeout the helper enforces; the helper verifies exactly this
    /// right and refuses (`authorizationRequired`) when it is missing or unknown while
    /// `authorization` is set.
    public var authorizationRight: String?

    public init(token: String = UUID().uuidString, arguments: [String], sshPassword: String? = nil,
                progressToken: String? = nil, callerUID: UInt32? = nil, authorization: Data? = nil,
                authorizationRight: String? = nil) {
        self.token = token
        self.arguments = arguments
        self.sshPassword = sshPassword
        self.progressToken = progressToken
        self.callerUID = callerUID
        self.authorization = authorization
        self.authorizationRight = authorizationRight
    }
}

/// The first value of `LSSHelperProtocol.toolchainTrust`'s reply (a raw string so the
/// protocol stays ObjC-representable); unknown text decodes as `.unusable` on the app side.
public enum HelperToolchainVerdict: String, Sendable {
    /// Root-owned, not writable by others: a run needs no password.
    case trusted
    /// A tool or search-path folder a non-root user can modify: a run needs the
    /// administrator-authentication dialog first (`Refusal.isClearedByAuthorization`).
    case authorizationRequired
    /// A refusal that no authentication clears (missing required tool, relative PATH
    /// entry): the helper cannot run the CLI; the app offers the sudo route.
    case unusable
}

/// What the helper replies instead of running: a stable code (the `RequestValidator.Refusal`
/// codes, plus `busy`, `cancelled`, `scanFile`, `spawn`, `error`, `malformedRequest`,
/// `requestTooLarge`, `authorizationRequired` and `authorizationUnavailable`) and one
/// sentence for the user.
/// Travels as JSON in the `String?` reply so the protocol stays ObjC-representable; the
/// app decodes it with `decode(_:)`, which also accepts a plain sentence (code `unknown`).
public struct HelperRefusal: Codable, Sendable, Hashable {
    /// A user-owned tool chain and no, malformed, expired or wrong-right authorization,
    /// or a request that names a right outside `HelperAuthorization.rights`.
    public static let authorizationRequiredCode = "authorizationRequired"
    /// The helper could not install its rights in the policy database.
    public static let authorizationUnavailableCode = "authorizationUnavailable"
    /// `cancel(token:)` arrived before the run reached the child table; nothing ran.
    public static let cancelledCode = "cancelled"

    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// True for the two codes of the authorization gate (the helper demanded, or could
    /// not install, its rights). Only `authorizationRequired` is cleared by a fresh
    /// administrator authentication (`isClearedByAuthentication`); `authorizationUnavailable`
    /// means the policy database refused the rights and no dialog will ever appear.
    public var isAuthorizationRefusal: Bool {
        code == Self.authorizationRequiredCode || code == Self.authorizationUnavailableCode
    }

    /// The one code a fresh administrator authentication can clear.
    public var isClearedByAuthentication: Bool {
        code == Self.authorizationRequiredCode
    }

    /// The run was cancelled by the app before the helper reached the child table.
    public var isCancellation: Bool {
        code == Self.cancelledCode
    }

    /// Compact JSON (`{"code":…,"message":…}`); falls back to the bare message if the
    /// encoder fails, which `decode` then classifies as `unknown`.
    public func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self), let text = String(data: data, encoding: .utf8) else {
            return message
        }
        return text
    }

    /// The refusal in `text`; non-JSON input becomes `HelperRefusal(code: "unknown", message: text)`.
    public static func decode(_ text: String) -> HelperRefusal {
        if let refusal = try? JSONDecoder().decode(HelperRefusal.self, from: Data(text.utf8)) {
            return refusal
        }
        return HelperRefusal(code: "unknown", message: text)
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
