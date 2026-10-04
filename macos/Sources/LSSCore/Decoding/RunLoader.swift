import Foundation

/// Decodes one task file into its envelope and typed payload. Returns nil when
/// no decoder exists for the task (the file is then shown as raw JSON only).
public typealias PayloadDecoder = @Sendable (TaskID, Data) throws -> (TaskEnvelope, any TaskPayload)?

/// One task JSON file found in a run directory (not yet decoded).
public struct TaskFileRef: Sendable, Hashable, Identifiable {
    public let task: TaskID
    public let url: URL
    /// N in `<stem>-device-N.json`; nil for single-entry files and the legacy
    /// non-indexed Task 10 file.
    public let deviceIndex: Int?
    public let isReadable: Bool

    public var id: String { url.path(percentEncoded: false) }
    public var fileName: String { url.lastPathComponent }

    public init(task: TaskID, url: URL, deviceIndex: Int?, isReadable: Bool) {
        self.task = task
        self.url = url
        self.deviceIndex = deviceIndex
        self.isReadable = isReadable
    }
}

/// What the browser knows about a run without decoding its task files.
public struct RunSummary: Sendable, Hashable, Identifiable {
    public let directory: URL
    public let hasManifest: Bool
    public let client: String?
    public let location: String?
    public let note: String?
    public let preparedBy: String?
    public let generatedAt: Date?
    public let generatedAtText: String?
    public let interface: String?
    public let modified: Date
    public let taskFiles: [TaskFileRef]
    public let reportTXT: URL?
    public let reportPDF: URL?

    public var id: String { directory.path(percentEncoded: false) }
    public var name: String { directory.lastPathComponent }
    public var presentTasks: Set<TaskID> { Set(taskFiles.map(\.task)) }
    public var unreadableCount: Int { taskFiles.filter { !$0.isReadable }.count }

    /// `Client — Location` with fallbacks to the directory name.
    public var title: String {
        let parts = [client, location].compactMap { Sentinel.value($0) }
        return parts.isEmpty ? name : parts.joined(separator: " — ")
    }

    /// Best available date for sorting: manifest, then directory mtime.
    public var sortDate: Date { generatedAt ?? modified }
}

/// Decoded state of one task file.
public enum TaskFileState: Sendable {
    case decoded(envelope: TaskEnvelope, payload: any TaskPayload, raw: JSONValue)
    /// Valid JSON that no typed decoder accepted (or no decoder exists).
    case rawOnly(envelope: TaskEnvelope?, raw: JSONValue, problem: String?)
    case corrupt(message: String)
    /// Exists but cannot be opened as this user (e.g. the 0600 stress files of old runs).
    case unreadable

    public var envelope: TaskEnvelope? {
        switch self {
        case .decoded(let envelope, _, _): envelope
        case .rawOnly(let envelope, _, _): envelope
        case .corrupt, .unreadable: nil
        }
    }

    public var raw: JSONValue? {
        switch self {
        case .decoded(_, _, let raw): raw
        case .rawOnly(_, let raw, _): raw
        case .corrupt, .unreadable: nil
        }
    }
}

public struct TaskFile: Sendable, Identifiable {
    public let ref: TaskFileRef
    public let state: TaskFileState

    public var id: String { ref.id }
    public var task: TaskID { ref.task }

    public init(ref: TaskFileRef, state: TaskFileState) {
        self.ref = ref
        self.state = state
    }
}

/// A run with its manifest, findings and decoded task files.
public struct RunDetail: Sendable {
    public let summary: RunSummary
    public let manifest: Manifest?
    public let findings: [Finding]
    public let hints: [Finding]
    public let files: [TaskFile]

    public init(summary: RunSummary, manifest: Manifest?, findings: [Finding], hints: [Finding], files: [TaskFile]) {
        self.summary = summary
        self.manifest = manifest
        self.findings = findings
        self.hints = hints
        self.files = files
    }

    public func files(for task: TaskID) -> [TaskFile] {
        files.filter { $0.task == task }
    }
}

/// Scans `$DATA_ROOT/output` and decodes runs. All file I/O happens here.
public actor RunLoader {
    public let outputDirectory: URL
    private let decoder: PayloadDecoder
    private let fileManager = FileManager.default

    public init(outputDirectory: URL, decoder: @escaping PayloadDecoder) {
        self.outputDirectory = outputDirectory
        self.decoder = decoder
    }

    // MARK: Listing

    /// All run directories, newest first.
    public func listRuns() -> [RunSummary] {
        // Path-based listing: the URL variant with .skipsHiddenFiles returns
        // nothing for directories below a hidden ancestor (e.g. a `.claude`
        // worktree), and the rest of this file uses paths anyway.
        let root = outputDirectory.path(percentEncoded: false)
        guard let names = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        var runs: [RunSummary] = []
        for name in names where !name.hasPrefix(".") {
            var isDirectory: ObjCBool = false
            let path = (root as NSString).appendingPathComponent(name)
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let url = URL(filePath: path, directoryHint: .isDirectory)
            if let summary = RunLoader.scanRun(directory: url, fileManager: fileManager) {
                runs.append(summary)
            }
        }
        return runs.sorted { $0.sortDate > $1.sortDate }
    }

    /// Reads one run directory's manifest and file list without decoding tasks.
    public nonisolated static func scanRun(directory: URL, fileManager: FileManager = .default) -> RunSummary? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return nil }
        let attributes = try? fileManager.attributesOfItem(atPath: directory.path(percentEncoded: false))
        let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast

        let manifestURL = directory.appending(path: "manifest.json")
        let manifest = loadManifest(at: manifestURL)

        var files: [TaskFileRef] = []
        for name in names where name.hasSuffix(".json") {
            guard let task = task(forFileName: name) else { continue }
            let url = directory.appending(path: name)
            files.append(TaskFileRef(
                task: task,
                url: url,
                deviceIndex: NaturalSort.deviceIndex(of: name),
                isReadable: fileManager.isReadableFile(atPath: url.path(percentEncoded: false))
            ))
        }
        files.sort { lhs, rhs in
            if lhs.task != rhs.task { return lhs.task < rhs.task }
            return (lhs.deviceIndex ?? -1, lhs.fileName) < (rhs.deviceIndex ?? -1, rhs.fileName)
        }

        // Reports: prefer the manifest's name, else the newest matching file.
        let txtURL = reportURL(in: directory, names: names, preferred: manifest?.reportFile, suffix: ".txt")
        let pdfURL = reportURL(in: directory, names: names, preferred: manifest?.pdfFile, suffix: ".pdf")

        // Date: manifest, else the dd-mm-yyyy stamp in the directory name.
        var generatedAt = manifest?.generatedDate
        var generatedText = manifest?.generatedAt
        if generatedAt == nil,
           let range = directory.lastPathComponent.range(of: "[0-9]{2}-[0-9]{2}-[0-9]{4}", options: .regularExpression) {
            let stamp = String(directory.lastPathComponent[range])
            generatedAt = LSSJSON.parseLocalDate(stamp)
            generatedText = generatedText ?? stamp
        }

        return RunSummary(
            directory: directory,
            hasManifest: manifest != nil,
            client: Sentinel.value(manifest?.client),
            location: Sentinel.value(manifest?.location),
            note: Sentinel.value(manifest?.note),
            preparedBy: Sentinel.value(manifest?.preparedBy),
            generatedAt: generatedAt,
            generatedAtText: generatedText,
            interface: manifest?.interface,
            modified: modified,
            taskFiles: files,
            reportTXT: txtURL,
            reportPDF: pdfURL
        )
    }

    /// Maps a file name to its task: exact single-entry names, `<stem>-device-N.json`
    /// for multi-entry tasks, and the legacy non-indexed Task 10 name.
    public nonisolated static func task(forFileName name: String) -> TaskID? {
        for task in TaskID.allCases {
            if name == task.outputFile { return task }
            if task.isMultiEntry, name.hasPrefix(task.outputStem + "-device-"), NaturalSort.deviceIndex(of: name) != nil {
                return task
            }
        }
        return nil
    }

    private nonisolated static func reportURL(in directory: URL, names: [String], preferred: String?, suffix: String) -> URL? {
        if let preferred, names.contains(preferred) {
            return directory.appending(path: preferred)
        }
        let candidates = names.filter { $0.hasPrefix("lss-network-tools-report-") && $0.hasSuffix(suffix) }
        guard let newest = candidates.sorted().last else { return nil }
        return directory.appending(path: newest)
    }

    private nonisolated static func loadManifest(at url: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? LSSJSON.decode(Manifest.self, from: data)
    }

    // MARK: Detail

    public func loadDetail(of summary: RunSummary) -> RunDetail {
        let manifest = RunLoader.loadManifest(at: summary.directory.appending(path: "manifest.json"))
        var findings = (try? Data(contentsOf: summary.directory.appending(path: "findings.json")))
            .flatMap { try? LSSJSON.decode(FindingsFile.self, from: $0) }?.findings ?? []
        var hints = (try? Data(contentsOf: summary.directory.appending(path: "remediation.json")))
            .flatMap { try? LSSJSON.decode(RemediationFile.self, from: $0) }?.hints ?? []
        // File position keeps otherwise identical findings distinct (`Finding.id`);
        // it has to be assigned before the severity sort below.
        for index in findings.indices { findings[index].ordinal = index }
        for index in hints.indices { hints[index].ordinal = index }
        let files = summary.taskFiles.map { TaskFile(ref: $0, state: decodeFile($0)) }
        return RunDetail(summary: summary, manifest: manifest, findings: findings.sorted(by: findingOrder), hints: hints, files: files)
    }

    private nonisolated func findingOrder(_ lhs: Finding, _ rhs: Finding) -> Bool {
        let l = lhs.severity?.rank ?? 99
        let r = rhs.severity?.rank ?? 99
        if l != r { return l < r }
        return (lhs.title ?? "") < (rhs.title ?? "")
    }

    private func decodeFile(_ ref: TaskFileRef) -> TaskFileState {
        guard ref.isReadable, let data = try? Data(contentsOf: ref.url) else {
            return .unreadable
        }
        let raw: JSONValue
        do {
            raw = try LSSJSON.decode(JSONValue.self, from: data)
        } catch {
            return .corrupt(message: LSSJSON.describe(error))
        }
        guard raw.isObject else {
            return .corrupt(message: "top-level JSON value is not an object")
        }
        let envelope = try? LSSJSON.decode(TaskEnvelope.self, from: data)
        do {
            if let (decodedEnvelope, payload) = try decoder(ref.task, data) {
                return .decoded(envelope: decodedEnvelope, payload: payload, raw: raw)
            }
            return .rawOnly(envelope: envelope, raw: raw, problem: nil)
        } catch {
            return .rawOnly(envelope: envelope, raw: raw, problem: LSSJSON.describe(error))
        }
    }
}
