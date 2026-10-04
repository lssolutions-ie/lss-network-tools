import Foundation

/// Exit codes of `lss-network-tools.sh` in non-interactive mode (PLAN §7.2).
public enum CLIExitCode: Int32, Sendable, Hashable, CaseIterable {
    /// Every task ended `success`, `completed_with_warnings` or `skipped`.
    case success = 0
    /// At least one task failed or wrote no JSON.
    case taskFailed = 1
    /// Usage or validation error (bad flag, interface, target, MAC, run directory…).
    case usage = 2
    /// `check_tools` found a required dependency missing.
    case missingDependencies = 3
    /// A stress task (10, 14, full audit) was requested without `--yes`.
    case consentRequired = 4
    /// The script was not run as root.
    case notRoot = 5
    /// Interrupted (SIGINT/SIGTERM).
    case interrupted = 130

    /// One user-facing sentence.
    public var summary: String {
        switch self {
        case .success: "The run completed."
        case .taskFailed: "The run completed, but at least one task failed or wrote no result."
        case .usage: "The command-line tool rejected the request (usage or validation error)."
        case .missingDependencies: "A required dependency is missing; see the checklist in the log."
        case .consentRequired: "The stress test needs explicit consent before it can run."
        case .notRoot: "The command-line tool must run as root."
        case .interrupted: "The run was interrupted."
        }
    }
}
