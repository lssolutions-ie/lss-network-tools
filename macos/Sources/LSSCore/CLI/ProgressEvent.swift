import Foundation

/// One `@@LSS {…}` line from the CLI's non-interactive mode (contract §1.2).
public struct ProgressEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case hello(version: String?, pid: Int?, tasks: [Int])
        case runDirectory(path: String, created: Bool?)
        case taskStart(task: Int, title: String?, index: Int?, total: Int?)
        case taskStage(task: Int, stage: String?, label: String?)
        case taskDone(task: Int, status: String?, exitCode: Int?, jsonFiles: [String])
        case reportBuilt(txt: String?)
        case pdfBuilt(pdf: String?)
        case pdfFailed(message: String?)
        case warning(code: String?, message: String?)
        case error(code: String?, message: String?, tools: [String])
        case bye(exitCode: Int?)
        case unknown(event: String)
    }

    public let kind: Kind
    public let timestamp: Date?
    public let protocolVersion: Int?
    /// The whole JSON object, for anything not modelled above.
    public let fields: JSONValue

    public init(kind: Kind, timestamp: Date?, protocolVersion: Int?, fields: JSONValue) {
        self.kind = kind
        self.timestamp = timestamp
        self.protocolVersion = protocolVersion
        self.fields = fields
    }

    /// The task of a `task_*` event.
    public var taskID: TaskID? {
        switch kind {
        case .taskStart(let task, _, _, _), .taskStage(let task, _, _), .taskDone(let task, _, _, _):
            TaskID(rawValue: task)
        default:
            nil
        }
    }

    /// `bye` — nothing follows.
    public var isTerminal: Bool {
        if case .bye = kind { return true }
        return false
    }
}
