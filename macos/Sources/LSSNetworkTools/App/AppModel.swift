import Foundation
import Observation
import Defaults
import LSSCore

extension Defaults.Keys {
    static let selectedInterface = Key<String>("selectedInterface", default: "")
    static let cliAppRootOverride = Key<String>("cliAppRootOverride", default: "")
    /// Name printed on the PDF cover (`--prepared-by`).
    static let preparedBy = Key<String>("preparedBy", default: "")
    /// Default for the New Run sheet's "Skip PDF report" toggle.
    static let skipPDFByDefault = Key<Bool>("skipPDFByDefault", default: false)
    static let lastClient = Key<String>("lastClient", default: "")
    static let lastLocation = Key<String>("lastLocation", default: "")
}

/// Root view model: CLI location, interfaces, sidebar selection, terminal
/// session, run coordinator and the New Run sheet.
@MainActor
@Observable
final class AppModel {
    var selection: SidebarItem? = .runAudit

    private(set) var cli: CLIInstall?
    private(set) var cliVersion: String?
    private(set) var interfaces: [NetworkInterface] = []
    private(set) var defaultRouteInterface: String?
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    var selectedInterface: String = Defaults[.selectedInterface] {
        didSet { Defaults[.selectedInterface] = selectedInterface }
    }

    var cliAppRootOverride: String = Defaults[.cliAppRootOverride] {
        didSet { Defaults[.cliAppRootOverride] = cliAppRootOverride }
    }

    var preparedBy: String = Defaults[.preparedBy] {
        didSet { Defaults[.preparedBy] = preparedBy }
    }

    var skipPDFByDefault: Bool = Defaults[.skipPDFByDefault] {
        didSet { Defaults[.skipPDFByDefault] = skipPDFByDefault }
    }

    let terminal = TerminalSession()
    let runBrowser = RunBrowserModel()
    let runCoordinator = RunCoordinator()

    /// True once the user asked for the interactive CLI (button or Terminal
    /// menu). The session never starts on its own any more: the pane is
    /// shared with non-interactive runs.
    var userRequestedInteractiveCLI = false

    /// Presents the New Run / Continue Run sheet while non-nil.
    var newRunSheet: NewRunSheetRequest?

    /// Set by `--output-dir` (automation / fixtures); otherwise the CLI's `output/` is browsed.
    var outputDirectoryOverride: URL?

    init() {
        runCoordinator.model = self
    }

    /// Points the run browser at the detected CLI's output directory (or the override).
    func configureRunBrowser() {
        runBrowser.configure(outputDirectory: outputDirectoryOverride ?? cli?.outputDirectory, decoder: PayloadDecoding.decode)
    }

    var guiVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var guiBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var selectedInterfaceDetails: NetworkInterface? {
        interfaces.first { $0.device == selectedInterface }
    }

    /// Re-detects the CLI install, its version, and the interface list.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let override = cliAppRootOverride
        let detected = CLIInstall.detect(overrideAppRoot: override.isEmpty ? nil : override)
        cli = detected

        async let interfaceList = NetworkInterfaces.list()
        async let defaultRoute = NetworkInterfaces.defaultRouteInterface()
        async let version: String? = {
            guard let detected else { return nil }
            return await CLIVersionProbe.version(of: detected)
        }()

        interfaces = await interfaceList
        defaultRouteInterface = await defaultRoute
        cliVersion = await version

        if selectedInterface.isEmpty || !interfaces.contains(where: { $0.device == selectedInterface }) {
            selectedInterface = defaultRouteInterface ?? interfaces.first?.device ?? ""
        }

        lastRefresh = .now
        launchTerminalIfNeeded()
        configureRunBrowser()
    }

    // MARK: Interactive CLI

    /// Starts the interactive CLI only if the user asked for it earlier and
    /// nothing else is using the terminal. No-op until the first `refresh()`.
    func launchTerminalIfNeeded() {
        guard userRequestedInteractiveCLI, lastRefresh != nil, terminal.state == .idle, !runCoordinator.isActive else { return }
        launchTerminal()
    }

    /// (Re)starts the interactive session in the embedded terminal:
    /// `sudo <wrapper>` when the CLI is installed, otherwise a login shell so
    /// the user can install it. Any non-interactive run is stopped first.
    func launchTerminal() {
        userRequestedInteractiveCLI = true
        runCoordinator.releaseTerminal()
        var environment = ProcessRunner.baseEnvironment
        environment["TERM_PROGRAM"] = "LSSNetworkTools"
        if let cli {
            let command = cli.launchCommand
            terminal.launch(
                executable: "/usr/bin/sudo",
                arguments: [command.executable] + command.arguments,
                environment: environment
            )
        } else {
            terminal.launch(executable: "/bin/zsh", arguments: ["-l"], environment: environment)
        }
    }

    /// Ends whatever the terminal is running: the active run (through the
    /// coordinator, so its state is recorded) or the interactive session.
    func endTerminalSession() {
        if runCoordinator.isActive {
            runCoordinator.cancel()
        } else {
            terminal.terminate()
        }
    }

    // MARK: New Run sheet

    /// Prefilled draft: interface from the run's manifest (continue) or the
    /// toolbar, last client/location, Prepared-by and Skip-PDF defaults, and
    /// the task selection (a single preselected task, pending audit tasks of a
    /// continued audit run, else the full audit).
    func makeDraft(task: TaskID?, existingRun: RunSummary?) -> RunDraft {
        var draft = RunDraft()
        draft.existingRun = existingRun
        draft.interface = existingRun?.interface.flatMap { $0.isEmpty ? nil : $0 } ?? selectedInterface
        draft.client = existingRun?.client ?? Defaults[.lastClient]
        draft.location = existingRun?.location ?? Defaults[.lastLocation]
        draft.note = existingRun?.note ?? ""
        draft.preparedBy = preparedBy.isEmpty ? (existingRun?.preparedBy ?? "") : preparedBy
        draft.skipPDF = skipPDFByDefault
        if let task {
            draft.selectionMode = .selected
            draft.selectedTasks = [task]
        } else if let existingRun {
            draft.selectionMode = .selected
            let present = existingRun.presentTasks
            if present.contains(where: \.isAuditTask) {
                draft.selectedTasks = Set(TaskID.auditTasks).subtracting(present)
            }
        } else {
            draft.selectionMode = .fullAudit
        }
        return draft
    }

    func presentNewRun(task: TaskID? = nil) {
        newRunSheet = NewRunSheetRequest(draft: makeDraft(task: task, existingRun: nil))
    }

    func presentContinueRun(_ run: RunSummary, task: TaskID? = nil) {
        newRunSheet = NewRunSheetRequest(draft: makeDraft(task: task, existingRun: run))
    }

    /// Persists the sheet's reusable values.
    func rememberRunDefaults(from draft: RunDraft) {
        preparedBy = draft.preparedBy.trimmed
        if !draft.isContinuing {
            Defaults[.lastClient] = draft.client.trimmed
            Defaults[.lastLocation] = draft.location.trimmed
        }
    }

    /// Starts the run and shows its progress (the Run Audit screen, unless a
    /// task screen — which shows the same progress view — is already selected).
    func startRun(_ request: RunTaskRequest, sshPassword: String?) {
        runCoordinator.start(request, sshPassword: sshPassword)
        switch selection {
        case .runAudit?, .task?: break
        default: selection = .runAudit
        }
    }

    /// `--build-report <run-dir>` for a run in the browser.
    func rebuildReport(for run: RunSummary) {
        let request = BuildReportRequest(
            runDirectory: run.directory,
            preparedBy: preparedBy.isEmpty ? nil : preparedBy,
            skipPDF: skipPDFByDefault
        )
        runCoordinator.buildReport(request)
        selection = .runAudit
    }

    /// Selects the run in Previous Runs (after a refresh so a new run is listed).
    func showInPreviousRuns(directory: URL) {
        selection = .previousRuns
        Task {
            await runBrowser.refresh()
            let target = directory.standardizedFileURL
            runBrowser.selectedRunID = runBrowser.runs.first { $0.directory.standardizedFileURL == target }?.id
        }
    }
}
