import SwiftUI
import LSSCore

/// The finished run's results, shown on the Run Audit screen where the
/// terminal used to be: the same Overview / Tasks / Report views as Previous
/// Runs, for the directory the run just wrote. It owns its own `RunLoader`
/// (pointed at the browsed output directory, with the app's decoder) and its
/// own `RunDetailSelection`, so browsing here never moves the Previous Runs
/// selection. The detail reloads when the coordinator refreshes the browser
/// (`reloadToken`: `task_done`, `report_built`, `pdf_built`, the end of the
/// run) and when the run directory itself changes on disk.
struct RunResultsView: View {
    enum Mode: Equatable {
        /// Several tasks (a full audit): the findings overview first.
        case overview
        /// Exactly one task ran: the Tasks tab, that task, grid collapsed.
        case task
        /// A report rebuild: the Report tab.
        case report
    }

    @Environment(AppModel.self) private var model
    let directory: URL
    let focusTask: TaskID?
    let mode: Mode
    /// `RunCoordinator.browserRefreshCount`; a change reloads the detail.
    let reloadToken: Int

    @State private var store = RunResultsStore()
    @State private var selection = RunDetailSelection()

    var body: some View {
        Group {
            if let detail = store.detail {
                RunDetailView(detail: detail, selection: selection, headerStyle: .compact)
            } else if store.isMissing {
                ContentUnavailableView {
                    Label("No results were written", systemImage: "tray")
                } description: {
                    Text("The run directory does not exist or holds no results:\n\(directory.path(percentEncoded: false))")
                }
            } else {
                ProgressView("Loading results…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: directory) {
            applyDefaults()
            await store.load(directory: directory, outputDirectory: model.outputDirectoryOverride ?? model.cli?.outputDirectory)
        }
        .onChange(of: reloadToken) {
            Task { await store.reload() }
        }
        .onChange(of: store.loadCount) {
            adjustSelection()
        }
        .onChange(of: mode) {
            applyDefaults()
            adjustSelection()
        }
    }

    /// `.task` → Tasks tab on `focusTask` with the grid hidden; `.overview` →
    /// Overview; `.report` → Report.
    private func applyDefaults() {
        switch mode {
        case .task:
            selection.tab = .tasks
            selection.task = focusTask
            selection.isGridCollapsed = focusTask != nil
        case .overview:
            selection.tab = .overview
        case .report:
            selection.tab = .report
        }
    }

    /// After a load: a focused task that wrote nothing cannot stay selected behind a
    /// collapsed grid (the picker would be empty), and one that appeared with a later
    /// reload is selected as the defaults intended.
    private func adjustSelection() {
        guard let detail = store.detail else { return }
        if let task = selection.task, detail.files(for: task).isEmpty {
            selection.task = nil
        }
        if mode == .task, selection.task == nil, let focusTask, !detail.files(for: focusTask).isEmpty {
            selection.task = focusTask
        }
        if selection.isGridCollapsed, selection.task == nil {
            selection.isGridCollapsed = false
        }
    }
}

/// Loads and watches one run directory for `RunResultsView`.
@MainActor
@Observable
final class RunResultsStore {
    private(set) var detail: RunDetail?
    /// The directory is gone or is not a run directory.
    private(set) var isMissing = false
    /// Bumped after every load so the view can re-check its selection.
    private(set) var loadCount = 0

    private var directory: URL?
    private var loader: RunLoader?
    private var watcher: DirectoryWatcher?

    /// Points the store at `directory`; `outputDirectory` is the browsed `output/`
    /// (the loader's root — the directory's parent when none is known).
    func load(directory: URL, outputDirectory: URL?) async {
        if self.directory != directory {
            self.directory = directory
            detail = nil
            isMissing = false
            loader = RunLoader(outputDirectory: outputDirectory ?? directory.deletingLastPathComponent(), decoder: PayloadDecoding.decode)
            watcher = DirectoryWatcher(url: directory) { [weak self] in
                Task { await self?.reload() }
            }
        }
        await reload()
    }

    func reload() async {
        guard let loader, let directory else { return }
        let loaded = await loader.loadDetail(ofDirectory: directory)
        // Ignore a result for a directory the view has moved away from meanwhile.
        guard self.loader === loader, self.directory == directory else { return }
        detail = loaded
        isMissing = loaded == nil
        loadCount += 1
    }
}
