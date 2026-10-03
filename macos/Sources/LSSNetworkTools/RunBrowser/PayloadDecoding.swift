import Foundation
import LSSCore

/// The app's payload decoder: the LSSCore registry (tasks 1–20).
enum PayloadDecoding {
    @Sendable
    static func decode(task: TaskID, data: Data) throws -> (TaskEnvelope, any TaskPayload)? {
        try TaskPayloadRegistry.decode(task: task, data: data)
    }
}
