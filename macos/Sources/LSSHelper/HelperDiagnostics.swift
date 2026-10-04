import Foundation
import LSSCore
import LSSXPC

/// Read-only diagnostics for running the helper binary by hand (launchd starts it with
/// no arguments, so these never run in the daemon):
///
///     LSSHelper --diagnose [--pid PID]     caller requirement this build applies,
///                                           optionally evaluated against a running process,
///                                           and whether the two authorization rights are
///                                           defined in the policy database
///     LSSHelper --check-arguments ARG...   RequestValidator against the live install.env,
///                                           as the invoking user; prints the validated
///                                           executable/argv/environment (secrets hidden)
///                                           and whether the tool chain is trusted or needs
///                                           administrator authentication (a user-owned
///                                           Homebrew prefix), or the refusal
///
/// Neither starts the listener nor executes anything.
enum HelperDiagnostics {
    /// nil when no diagnostic flag was given (start the daemon); otherwise an exit code.
    static func run(_ arguments: [String]) -> Int32? {
        let rest = Array(arguments.dropFirst())
        guard let first = rest.first else { return nil }
        switch first {
        case "--diagnose":
            var pid: pid_t?
            if rest.count >= 3, rest[1] == "--pid" { pid = pid_t(rest[2]) }
            return diagnose(pid: pid)
        case "--check-arguments":
            return checkArguments(Array(rest.dropFirst()))
        case "--version":
            print("LSSHelper \(LSSHelperBuildVersion) (protocol \(LSSHelperProtocolVersion))")
            return 0
        default:
            FileHandle.standardError.write(Data("usage: LSSHelper [--diagnose [--pid PID] | --check-arguments ARG... | --version]\n".utf8))
            return 2
        }
    }

    private static func diagnose(pid: pid_t?) -> Int32 {
        let validation = CallerValidation()
        print("LSSHelper \(LSSHelperBuildVersion) (protocol \(LSSHelperProtocolVersion))")
        print("team identifier: \(validation.teamIdentifier ?? "none (ad-hoc signature: degraded caller validation)")")
        print("enclosing app:   \(validation.appBundle?.path(percentEncoded: false) ?? "not found")")
        switch AdminGroupMembership.check(uid: getuid()) {
        case .member: print("admin check:     uid \(getuid()) is an administrator (connections from it would be served)")
        case .notMember: print("admin check:     uid \(getuid()) is NOT an administrator (connections from it would be refused)")
        case .failed(let reason): print("admin check:     cannot be determined for uid \(getuid()) — \(reason) (connections would be refused)")
        }
        if let app = validation.appBundle {
            print("app cdhash:      \(CallerValidation.cdhash(of: app) ?? "unavailable")")
        }
        // Readable by any user; "missing or differs" until the helper ran once as root.
        let rights = AuthorizationGate.rightsInstalled()
        for right in HelperAuthorization.rights {
            print("right \(right): \(rights[right] == true ? "installed" : "missing or differs")")
        }
        guard let requirement = validation.requirement() else {
            print("requirement:     none — every connection would be rejected")
            return 1
        }
        print("requirement:     \(requirement)")
        guard let pid else { return 0 }
        guard let parsed = CallerValidation.parse(requirement) else {
            print("pid \(pid): requirement does not parse")
            return 1
        }
        if validation.teamIdentifier != nil {
            // With a Team ID only the requirement applies; check it the same way.
            switch CallerValidation.check(pid: pid, requirement: parsed, appBundle: validation.appBundle) {
            case .success: print("pid \(pid): satisfies the requirement")
            case .failure(let reason): print("pid \(pid): \(reason)")
            }
            return 0
        }
        switch CallerValidation.check(pid: pid, requirement: parsed, appBundle: validation.appBundle) {
        case .success:
            print("pid \(pid): ACCEPTED (requirement satisfied, executable inside the enclosing app)")
            return 0
        case .failure(let reason):
            print("pid \(pid): REJECTED — \(reason)")
            return 1
        }
    }

    private static func checkArguments(_ arguments: [String]) -> Int32 {
        let validator = RequestValidator()
        do {
            let validated = try validator.validate(arguments: arguments, sshPassword: nil, callerUID: getuid(), toolchainPolicy: .report)
            print("executable:  \(validated.executable)")
            print("arguments:   \(validated.arguments.map { "\"\($0)\"" }.joined(separator: " "))")
            for key in validated.environment.keys.sorted() {
                print("environment: \(key)=\(RequestValidator.secretEnvironmentKeys.contains(key) ? "(hidden)" : validated.environment[key] ?? "")")
            }
            if let runDirectory = validated.runDirectory { print("run dir:     \(runDirectory)") }
            switch validated.toolchain {
            case .trusted:
                print("tool chain:  trusted")
            case .untrusted(let refusal):
                print("tool chain:  administrator authentication required — \(refusal.description)")
            case .unusable(let refusal):
                // Unreachable (`validate` throws it under both policies); kept exhaustive.
                print("tool chain:  cannot run — \(refusal.description)")
            }
            return 0
        } catch let refusal as RequestValidator.Refusal {
            print("refused (\(refusal.code)): \(refusal.description)")
            return 1
        } catch {
            print("error: \(error)")
            return 1
        }
    }
}
