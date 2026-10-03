import Foundation

/// One `id|Title|output-file.json` line of the script's TASKS_DATA table.
public struct TaskCatalogEntry: Sendable, Equatable, Hashable {
    public let id: Int
    public let title: String
    public let outputFile: String

    public init(id: Int, title: String, outputFile: String) {
        self.id = id
        self.title = title
        self.outputFile = outputFile
    }
}

/// Parses the task table the bash script keeps in its `TASKS_DATA` heredoc.
/// Used by the drift test (TaskID vs script) and, later, by `--run-task list`.
public enum TaskCatalog {
    /// Parses `id|Title|file` lines. Blank lines and lines without exactly two
    /// separators are ignored.
    public static func parse(tasksData: String) -> [TaskCatalogEntry] {
        var entries: [TaskCatalogEntry] = []
        for rawLine in tasksData.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 3, let id = Int(parts[0]) else { continue }
            entries.append(TaskCatalogEntry(id: id, title: parts[1], outputFile: parts[2]))
        }
        return entries
    }

    /// Extracts the body of
    /// ```
    /// TASKS_DATA=$(cat <<'TASKS'
    /// ...
    /// TASKS
    /// )
    /// ```
    /// from the full text of `lss-network-tools.sh`.
    public static func extractTasksData(fromScript script: String) -> String? {
        guard let start = script.range(of: "TASKS_DATA=$(cat <<'TASKS'\n") else { return nil }
        let afterStart = script[start.upperBound...]
        guard let end = afterStart.range(of: "\nTASKS\n") else { return nil }
        return String(afterStart[..<end.lowerBound])
    }
}
