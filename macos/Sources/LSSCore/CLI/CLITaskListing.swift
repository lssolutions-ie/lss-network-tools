import Foundation

/// Output of `lss-network-tools --run-task list` (contract §1.3).
public struct CLITaskListing: Sendable, Hashable, Decodable {
    public struct Entry: Sendable, Hashable, Decodable {
        public let id: Int
        public let title: String
        public let file: String
        public let multi: Bool
        /// `core` (1–12), `custom` (13–16) or `specialist` (17–20).
        public let group: String

        public init(id: Int, title: String, file: String, multi: Bool, group: String) {
            self.id = id
            self.title = title
            self.file = file
            self.multi = multi
            self.group = group
        }
    }

    public let version: String?
    public let tasks: [Entry]

    public init(version: String?, tasks: [Entry]) {
        self.version = version
        self.tasks = tasks
    }

    public static func parse(_ data: Data) throws -> CLITaskListing {
        try LSSJSON.decode(CLITaskListing.self, from: data)
    }

    /// Human sentences describing every difference between the CLI's listing and
    /// the app's catalog: missing/extra ids, title, output-file, multi-entry or
    /// group mismatches. Empty when the two agree.
    public func drift(against catalog: [TaskID]) -> [String] {
        var sentences: [String] = []
        var catalogByID: [Int: TaskID] = [:]
        for task in catalog { catalogByID[task.rawValue] = task }

        var seen = Set<Int>()
        for entry in tasks.sorted(by: { $0.id < $1.id }) {
            guard seen.insert(entry.id).inserted else {
                sentences.append("The CLI lists task \(entry.id) more than once.")
                continue
            }
            guard let task = catalogByID[entry.id] else {
                sentences.append("The CLI lists task \(entry.id) (\(entry.title)), which the app does not know.")
                continue
            }
            if entry.title != task.title {
                sentences.append("Task \(entry.id): the CLI calls it “\(entry.title)” but the app expects “\(task.title)”.")
            }
            if entry.file != task.outputFile {
                sentences.append("Task \(entry.id): the CLI writes “\(entry.file)” but the app expects “\(task.outputFile)”.")
            }
            if entry.multi != task.isMultiEntry {
                sentences.append("Task \(entry.id): the CLI reports multi=\(entry.multi) but the app expects multi=\(task.isMultiEntry).")
            }
            let expectedGroup = Self.groupName(task.group)
            if entry.group != expectedGroup {
                sentences.append("Task \(entry.id): the CLI puts it in group “\(entry.group)” but the app expects “\(expectedGroup)”.")
            }
        }

        for task in catalog.sorted() where !seen.contains(task.rawValue) {
            sentences.append("The CLI does not list task \(task.rawValue) (\(task.title)).")
        }
        return sentences
    }

    /// The `group` string the CLI uses for each sidebar group.
    private static func groupName(_ group: TaskGroup) -> String {
        switch group {
        case .coreAudit: "core"
        case .customTarget: "custom"
        case .specialist: "specialist"
        }
    }
}
