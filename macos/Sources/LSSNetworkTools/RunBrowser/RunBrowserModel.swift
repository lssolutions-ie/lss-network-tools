import Foundation
import Observation
import LSSCore

enum RunDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case tasks = "Tasks"
    case report = "Report"
    var id: String { rawValue }
}

/// State for the Previous Runs browser: the run list, the selected run's
/// decoded detail, and a directory watcher that refreshes both.
@MainActor
@Observable
final class RunBrowserModel {
    private(set) var runs: [RunSummary] = []
    private(set) var detail: RunDetail?
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    private(set) var lastError: String?
    var selectedRunID: RunSummary.ID? {
        didSet { if selectedRunID != oldValue { Task { await loadSelectedDetail() } } }
    }
    var selectedTask: TaskID?
    var detailTab: RunDetailTab = .overview
    /// Tasks tab: hide the completion grid so the selected task's results get the full height.
    var isGridCollapsed = false

    private var loader: RunLoader?
    private var outputDirectory: URL?
    private var watcher: DirectoryWatcher?
    private var runWatcher: DirectoryWatcher?

    var selectedRun: RunSummary? {
        runs.first { $0.id == selectedRunID }
    }

    /// Points the browser at a CLI install (or nil when none is installed).
    func configure(outputDirectory: URL?, decoder: @escaping PayloadDecoder) {
        guard outputDirectory != self.outputDirectory else { return }
        self.outputDirectory = outputDirectory
        watcher = nil
        runWatcher = nil
        detail = nil
        selectedRunID = nil
        guard let outputDirectory else {
            loader = nil
            runs = []
            return
        }
        loader = RunLoader(outputDirectory: outputDirectory, decoder: decoder)
        watcher = DirectoryWatcher(url: outputDirectory) { [weak self] in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard let loader else { return }
        isLoading = true
        defer { isLoading = false }
        let list = await loader.listRuns()
        runs = list
        hasLoadedOnce = true
        if let selectedRunID, !list.contains(where: { $0.id == selectedRunID }) {
            self.selectedRunID = nil
        } else if selectedRunID != nil {
            await loadSelectedDetail()
        }
    }

    func loadSelectedDetail() async {
        guard let loader, let run = selectedRun else {
            detail = nil
            runWatcher = nil
            return
        }
        detail = await loader.loadDetail(of: run)
        if runWatcher?.url != run.directory {
            runWatcher = DirectoryWatcher(url: run.directory) { [weak self] in
                Task { await self?.refresh() }
            }
        }
        if let selectedTask, detail?.files(for: selectedTask).isEmpty == true {
            self.selectedTask = nil
        }
    }
}

/// Kqueue-based watcher on one directory; coalesces bursts of events.
@MainActor
final class DirectoryWatcher {
    let url: URL
    private let source: DispatchSourceFileSystemObject?
    private let descriptor: Int32
    private var pending: Task<Void, Never>?

    init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.url = url
        descriptor = open(url.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else {
            source = nil
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .extend],
            queue: .main
        )
        self.source = source
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending?.cancel()
                self.pending = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    onChange()
                }
            }
        }
        let fd = descriptor
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source?.cancel()
    }
}
