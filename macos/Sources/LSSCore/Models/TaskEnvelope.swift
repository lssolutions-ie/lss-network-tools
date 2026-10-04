import Foundation

/// `status` as written by the bash script. Open: an unknown string decodes as
/// `.other` instead of failing the whole file (research 03, hazard 6).
public enum TaskStatus: Sendable, Hashable, Decodable, CustomStringConvertible {
    case success
    case completedWithWarnings
    case failed
    case skipped
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "success": self = .success
        case "completed_with_warnings": self = .completedWithWarnings
        case "failed": self = .failed
        case "skipped": self = .skipped
        default: self = .other(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
    }

    public var rawValue: String {
        switch self {
        case .success: "success"
        case .completedWithWarnings: "completed_with_warnings"
        case .failed: "failed"
        case .skipped: "skipped"
        case .other(let raw): raw
        }
    }

    /// Human label.
    public var description: String {
        switch self {
        case .success: "Success"
        case .completedWithWarnings: "Completed with warnings"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .other(let raw): raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// `skipped` is not a failure even though the script writes `success: false` for it.
    public var isFailure: Bool { self == .failed }
}

public struct TaskError: Decodable, Sendable, Hashable {
    public let code: String?
    public let message: String?

    public init(code: String?, message: String?) {
        self.code = code
        self.message = message
    }
}

/// The fields every task JSON shares. `error` and `warnings` are missing in
/// some files (Tasks 19/20) and `null` in others, so both are tolerated.
/// `edited_at` (ISO-8601 UTC) is stamped by Manage Results → Edit Results since
/// v1.2.252 and marks a result whose values are no longer the engine's measurement.
public struct TaskEnvelope: Decodable, Sendable, Hashable {
    public let status: TaskStatus?
    public let success: Bool?
    public let error: TaskError?
    public let warnings: [String]
    public let skipReason: String?
    public let skipMessage: String?
    public let editedAt: String?

    public init(status: TaskStatus?, success: Bool?, error: TaskError?, warnings: [String], skipReason: String? = nil, skipMessage: String? = nil, editedAt: String? = nil) {
        self.status = status
        self.success = success
        self.error = error
        self.warnings = warnings
        self.skipReason = skipReason
        self.skipMessage = skipMessage
        self.editedAt = editedAt
    }

    private enum CodingKeys: String, CodingKey {
        case status, success, error, warnings, skipReason, skipMessage, editedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(TaskStatus.self, forKey: .status)
        success = try container.decodeIfPresent(Bool.self, forKey: .success)
        error = try container.decodeIfPresent(TaskError.self, forKey: .error)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        skipReason = try container.decodeIfPresent(String.self, forKey: .skipReason)
        skipMessage = try container.decodeIfPresent(String.self, forKey: .skipMessage)
        editedAt = Sentinel.value(try? container.decodeIfPresent(String.self, forKey: .editedAt))
    }

    /// `edited_at` parsed as a date (nil when absent or not ISO-8601).
    public var editedDate: Date? { editedAt.flatMap(LSSJSON.parseISO8601) }

    /// True when Edit Results stamped this file after the run.
    public var wasEdited: Bool { editedAt != nil }

    /// Effective status: `status` when present, otherwise derived from `success`.
    public var effectiveStatus: TaskStatus {
        if let status { return status }
        if let success { return success ? .success : .failed }
        return .other("unknown")
    }
}

/// Task-specific payload types conform to this; they contain only the
/// task's own fields (all optional) and are decoded with synthesized Codable.
public protocol TaskPayload: Decodable, Sendable {
    static var taskIDs: [TaskID] { get }
}

/// Envelope + payload decoded from the same JSON object.
public struct TaskResult<Payload: TaskPayload>: Decodable, Sendable {
    public let envelope: TaskEnvelope
    public let payload: Payload

    public init(envelope: TaskEnvelope, payload: Payload) {
        self.envelope = envelope
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        envelope = try TaskEnvelope(from: decoder)
        payload = try Payload(from: decoder)
    }
}
