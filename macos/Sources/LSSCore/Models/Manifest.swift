import Foundation

/// `manifest.json` written by `write_manifest_for_current_run`. Older runs
/// list 17 or 18 tasks. `artifacts` lists every file in the run directory except
/// `manifest.json` at the moment the manifest is written, so it includes the PDF
/// whenever one already exists (e.g. after Rebuild Report) and omits a PDF that
/// is generated afterwards; `pdfFile` below is the reliable way to find it.
public struct Manifest: Decodable, Sendable, Hashable {
    public struct TaskEntry: Decodable, Sendable, Hashable {
        @LenientInt public var taskId: Int?
        public var title: String?
        public var jsonFile: String?
        public var jsonPresent: Bool?
        public var jsonFiles: [String]?
        public var rawPrefix: String?
        /// SHA-256 (hex) of the task's result file when the manifest was written
        /// (v1.2.252); a file whose checksum differs was changed after the run.
        public var sha256: String?
        /// Result file mtime as ISO-8601 UTC (v1.2.252).
        public var writtenAt: String?

        public var task: TaskID? { taskId.flatMap(TaskID.init(rawValue:)) }

        /// `written_at` parsed as a date.
        public var writtenDate: Date? { writtenAt.flatMap(LSSJSON.parseISO8601) }

        /// The recorded checksum for `fileName`, if the manifest holds one for it: the
        /// task-level `sha256` belongs to the task's single result file, so a
        /// multi-entry task with several files has no per-file checksum here.
        public func expectedSHA256(for fileName: String) -> String? {
            guard let sha256 = Sentinel.value(sha256) else { return nil }
            if fileName == jsonFile { return sha256.lowercased() }
            if let jsonFiles, jsonFiles == [fileName] { return sha256.lowercased() }
            return nil
        }
    }

    /// The entry for `task`, if the manifest lists it.
    public func entry(for task: TaskID) -> TaskEntry? {
        tasks?.first { $0.task == task }
    }

    public struct Artifact: Decodable, Sendable, Hashable {
        public var path: String?
        public var type: String?
    }

    public var generatedAt: String?
    public var client: String?
    public var location: String?
    public var note: String?
    public var preparedBy: String?
    public var runDirectory: String?
    public var selectedInterface: String?
    public var reportFile: String?
    public var debugFile: String?
    public var tasks: [TaskEntry]?
    public var artifacts: [Artifact]?

    /// `generated_at` parsed as a local date.
    public var generatedDate: Date? { generatedAt.flatMap(LSSJSON.parseLocalDate) }

    /// Interface name without the `"unknown"` sentinel.
    public var interface: String? { Sentinel.value(selectedInterface) }

    /// Expected PDF name: the TXT report name with `.pdf`.
    public var pdfFile: String? {
        guard let reportFile, reportFile.hasSuffix(".txt") else { return nil }
        return String(reportFile.dropLast(4)) + ".pdf"
    }
}

/// Severity written by `append_finding_record`. Open enum.
public enum FindingSeverity: Sendable, Hashable, Decodable, Comparable {
    case high, warning, info, advice, other(String)

    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "high", "critical": self = .high
        case "warning", "warn", "medium": self = .warning
        case "info", "low": self = .info
        case "advice", "hint": self = .advice
        default: self = .other(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public var rawValue: String {
        switch self {
        case .high: "high"
        case .warning: "warning"
        case .info: "info"
        case .advice: "advice"
        case .other(let raw): raw
        }
    }

    /// Sort rank: high first.
    public var rank: Int {
        switch self {
        case .high: 0
        case .warning: 1
        case .info: 2
        case .advice: 3
        case .other: 4
        }
    }

    public static func < (lhs: FindingSeverity, rhs: FindingSeverity) -> Bool { lhs.rank < rhs.rank }
}

public struct Finding: Decodable, Sendable, Hashable, Identifiable {
    public var severity: FindingSeverity?
    public var title: String?
    public var detail: String?
    public var source: String?
    /// Position in `findings.json` / `remediation.json`, assigned by
    /// `RunLoader.loadDetail` before sorting (never decoded). Task 10 writes
    /// byte-identical indicator findings for every device file, so content alone
    /// cannot identify a row; without this a SwiftUI `Table` sees duplicate ids.
    public var ordinal: Int = 0

    private enum CodingKeys: String, CodingKey {
        case severity, title, detail, source
    }

    public var id: String { "\(ordinal)|\(severity?.rawValue ?? "")|\(title ?? "")|\(source ?? "")|\(detail ?? "")" }

    /// The task that produced this finding, derived from `source` (a file basename).
    public var task: TaskID? {
        guard let source else { return nil }
        let stem = source.replacingOccurrences(of: "-device-[0-9]+\\.json$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.json$", with: "", options: .regularExpression)
        if let exact = TaskID.allCases.first(where: { $0.outputStem == stem }) { return exact }
        if stem == "dns" { return .dnsScan }
        return nil
    }
}

/// `findings.json`
public struct FindingsFile: Decodable, Sendable, Hashable {
    public var findings: [Finding]?
}

/// `remediation.json`
public struct RemediationFile: Decodable, Sendable, Hashable {
    public var hints: [Finding]?
}
