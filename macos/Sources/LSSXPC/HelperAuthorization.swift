import Foundation

/// The Authorization Services rights behind the helper's tool-chain gate (contract
/// §11.2, security model S2–S3 and S5).
///
/// A password-less root helper must not run binaries a non-root user can replace: the
/// validator refuses such a tool chain. On Macs where Homebrew belongs to the user that
/// is every Mac, so the owner chose the boundary `sudo` already draws — the same tools
/// run as root *after the user authenticates as an administrator*. The app obtains the
/// credential through the standard macOS dialog on an `AuthorizationRef`, sends its
/// external form with the request, and the helper (root) checks it against these rights.
///
/// Both rights are defined by the helper in the policy database with an explicit
/// **dictionary** rule rather than a canned rule *name* (`authenticate-admin`…), whose
/// semantics a macOS release could change under us. What makes the gate real is that
/// the helper verifies the *app's* token, which holds a credential only after the
/// dialog. `allow-root = false` is defence in depth on top of that: authd grants a
/// right automatically when the token's *creator* is uid 0, so the setting keeps a
/// root-created token — the helper's own ref in `ensureRights`, or a default rule —
/// from ever satisfying these rights (the app's token is created by the user, so the
/// flag never fires for it either way). `shared = false` keeps the credential private
/// to the app's `AuthorizationRef` (no other app, no other ref).
///
/// Credentials are per *token*, not per right: once the user has authenticated, a
/// token satisfies every rule that accepts that user and that credential age. The right
/// *name* is therefore the only thing that selects between the two timeouts, which is
/// why a request names the right it was authenticated for
/// (`HelperRunRequest.authorizationRight`) and the helper verifies that single right
/// (contract §11.2, S2).
///
/// Foundation only: the Security framework is imported by the helper and the app, not
/// here, so `LSSCoreTests` stay Foundation-only.
public enum HelperAuthorization {
    /// `timeout = 300`: when a request names this right, the helper accepts a credential
    /// no older than five minutes (the cadence `sudo` uses).
    public static let fiveMinuteRight = "ie.lssolutions.lss-network-tools.helper.run-with-user-owned-tools"
    /// `timeout = 2147483647`: when a request names this right, the credential is bounded
    /// only by the app's `AuthorizationRef` ("once per app session"; destroyed by Lock now
    /// or at quit). The helper does not bound it further.
    public static let sessionRight = fiveMinuteRight + ".session"
    /// Every right a request may name (`HelperRunRequest.authorizationRight`); the helper
    /// verifies exactly the named one and refuses any other name.
    public static let rights = [fiveMinuteRight, sessionRight]

    /// `kAuthorizationExternalFormLength`: an `AuthorizationExternalForm` is exactly this many bytes.
    public static let externalFormLength = 32

    /// Shown in the authentication dialog (installed as the right's description).
    public static let dialogDescription = "LSS Network Tools wants to run a network audit as root."

    /// `timeout` of `fiveMinuteRight`, in seconds.
    public static let fiveMinuteTimeout = 300
    /// `timeout` of `sessionRight`: the largest value the policy database accepts, so
    /// only the app's `AuthorizationRef` bounds the credential.
    public static let sessionTimeout = 2_147_483_647

    /// The S3 keys every right definition must carry with exactly these semantics.
    public static let ruleKeys = ["class", "group", "authenticate-user", "allow-root", "session-owner", "shared", "timeout"]

    public static func isWellFormed(externalForm: Data) -> Bool {
        externalForm.count == externalFormLength
    }

    /// The dictionary rule for `right` (S3). `comment` is for administrators reading the
    /// policy database; `dialogDescription` is what users see. `right` must be one of
    /// `rights`: an unknown name is a programming error, never silently the 300 s rule.
    public static func rule(for right: String) -> [String: Any] {
        precondition(rights.contains(right), "unknown authorization right \(right)")
        let session = right == sessionRight
        return [
            "class": "user",
            "group": "admin",
            "authenticate-user": true,
            // authd grants a right automatically to a token *created* by uid 0; this
            // keeps a root-created token (the helper's own, or a default rule) out.
            // The gate itself rests on verifying the app's user-created token.
            "allow-root": false,
            "session-owner": false,
            // Not reusable by other applications or other AuthorizationRefs.
            "shared": false,
            "timeout": session ? sessionTimeout : fiveMinuteTimeout,
            "comment": session
                ? "LSS Network Tools privileged helper: run a network audit as root with a user-owned tool chain, authenticated once per app session (the credential lives as long as the app's AuthorizationRef)."
                : "LSS Network Tools privileged helper: run a network audit as root with a user-owned tool chain, authenticated as an administrator; the credential expires after five minutes.",
        ]
    }

    /// Whether `existing` (as `AuthorizationRightGet` returns it) carries every S3 key
    /// with the value `rule(for:)` prescribes. Values read back from the policy database
    /// arrive as `NSNumber`/`NSString`, so numbers and booleans are compared through
    /// their bridged forms; `comment` is not compared (a site administrator may annotate).
    public static func ruleMatches(_ existing: [String: Any], right: String) -> Bool {
        guard rights.contains(right) else { return false }
        let expected = rule(for: right)
        for key in ruleKeys {
            guard let want = expected[key], let have = existing[key] else { return false }
            switch want {
            case let text as String:
                guard string(have) == text else { return false }
            case let flag as Bool:
                guard bool(have) == flag else { return false }
            case let number as Int:
                guard int(have) == number else { return false }
            default:
                return false
            }
        }
        return true
    }

    // MARK: Bridged values

    static func string(_ value: Any) -> String? {
        value as? String
    }

    /// `Bool`, or an `NSNumber` holding a boolean. A number that is not 0/1 is not a
    /// boolean (a `timeout` of 300 must never read as `true`).
    static func bool(_ value: Any) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber {
            switch number.intValue {
            case 0: return false
            case 1: return true
            default: return nil
            }
        }
        return nil
    }

    /// `Int`, or an `NSNumber` holding an integral value. A boolean is not a number:
    /// `allow-root = true` must never read as `timeout = 1`.
    static func int(_ value: Any) -> Int? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.intValue
        }
        return value as? Int
    }
}
