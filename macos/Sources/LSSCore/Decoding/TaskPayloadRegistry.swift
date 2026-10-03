import Foundation

/// Routes a task's JSON to its typed payload decoder. Tasks 1–12 and 14 live in
/// `CoreAuditPayloads.swift`, 13 and 15–20 in `SpecialistPayloads.swift`.
public enum TaskPayloadRegistry {
    /// Returns nil only if no decoder exists for the task (none today).
    @Sendable
    public static func decode(task: TaskID, data: Data) throws -> (TaskEnvelope, any TaskPayload)? {
        if let result = try decodeCoreAuditPayload(task: task, data: data) { return result }
        return try decodeSpecialistPayload(task: task, data: data)
    }

    /// Convenience: decode straight from a file URL.
    public static func decode(task: TaskID, fileURL: URL) throws -> (TaskEnvelope, any TaskPayload)? {
        try decode(task: task, data: Data(contentsOf: fileURL))
    }
}
