import Foundation
import Observation
import LSSCore

enum RunDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case tasks = "Tasks"
    case report = "Report"
    var id: String { rawValue }
}

/// What `RunDetailView` shows of one run: the tab, the task picked in the Tasks
/// tab, and whether its grid is collapsed. The Previous Runs browser owns one
/// (`RunBrowserModel.selection`); the Run Audit screen's results view owns its own,
/// so browsing there never moves the browser's selection.
@MainActor
@Observable
final class RunDetailSelection {
    var tab: RunDetailTab
    var task: TaskID?
    /// Tasks tab: hide the completion grid so the selected task's results get the full height.
    var isGridCollapsed: Bool

    init(tab: RunDetailTab = .overview, task: TaskID? = nil, isGridCollapsed: Bool = false) {
        self.tab = tab
        self.task = task
        self.isGridCollapsed = isGridCollapsed
    }
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
    /// Tab, task and grid state of the selected run's detail.
    let selection = RunDetailSelection()

    /// The run whose "Delete this run?" confirmation is showing (header button or
    /// the row's context menu); nil otherwise.
    var runPendingDeletion: RunSummary?
    /// Why the last Delete did not start (`AppModel.deleteRun`), shown in the header.
    var deleteProblem: String?

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
        // Switching directories (automation `--output-dir`, a re-detected CLI) must not leave the
        // previous directory's list visible: a caller waiting on `hasLoadedOnce` would otherwise
        // select a run from the old list and load its detail through the new loader.
        runs = []
        hasLoadedOnce = false
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
        // A reconfigure may have replaced the loader while the listing ran; drop stale results.
        guard self.loader === loader else { return }
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
        let loaded = await loader.loadDetail(of: run)
        // Ignore the result if the directory or the selection changed meanwhile.
        guard self.loader === loader, selectedRunID == run.id else { return }
        detail = loaded
        if runWatcher?.url != run.directory {
            runWatcher = DirectoryWatcher(url: run.directory) { [weak self] in
                Task { await self?.refresh() }
            }
        }
        if let task = selection.task, detail?.files(for: task).isEmpty == true {
            selection.task = nil
        }
    }
}

/// Kqueue-based watcher on one directory; coalesces bursts of events.
///
/// The descriptor is opened off the main actor: `open()` on a directory that
/// the iCloud file provider is syncing (anything under ~/Documents, such as
/// the test fixtures) can block for seconds or longer, and it used to block
/// the main thread inside `RunBrowserModel.configure`. Events are delivered
/// once the source is attached; the browser's own first `refresh()` does not
/// depend on it.
@MainActor
final class DirectoryWatcher {
    let url: URL
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?
    private var opening: Task<Void, Never>?

    init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.url = url
        let path = url.path(percentEncoded: false)
        opening = Task { [weak self] in
            let descriptor = await Task.detached(priority: .utility) { open(path, O_EVTONLY) }.value
            guard let self, !Task.isCancelled else {
                if descriptor >= 0 { close(descriptor) }
                return
            }
            self.opening = nil
            self.attach(descriptor: descriptor, onChange: onChange)
        }
    }

    private func attach(descriptor: Int32, onChange: @escaping @MainActor @Sendable () -> Void) {
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .extend],
            queue: .main
        )
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
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
        // A debounce still waiting would otherwise fire `onChange` for a
        // directory nobody watches any more (e.g. the previous run's); an
        // `open()` still in flight closes its descriptor when it returns.
        pending?.cancel()
        opening?.cancel()
    }
}
