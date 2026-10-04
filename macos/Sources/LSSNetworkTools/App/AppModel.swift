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
    /// `CFBundleVersion` of the build whose Setup & Permissions sheet was closed with
    /// Done; the sheet opens on its own on the first launch of every other build.
    static let setupSeenForBuild = Key<String>("setupSeenForBuild", default: "")
    /// When the Setup sheet last asked macOS for Local Network access (there is no API
    /// to read that permission back, so the time of the request is all the app knows).
    static let localNetworkRequestedAt = Key<Date?>("localNetworkRequestedAt")
    /// Run Audit screen: whether the terminal log is shown under the progress/results.
    /// The log opens on its own while sudo waits for the password, whatever this says.
    static let showRunLog = Key<Bool>("showRunLog", default: false)
}

/// Whether the installed command-line tool accepts `--run-task` /
/// `--build-report`, probed with `--run-task list` (no root needed) on every
/// `AppModel.refresh()`. Everything that starts a run is gated on it: a CLI
/// that predates non-interactive mode (v1.2.248 and older) would otherwise be
/// launched through sudo and fail with "Unknown option" only after the
/// password was typed.
enum NonInteractiveSupport: Equatable, Sendable {
    /// Not probed yet: no CLI is installed, or the probe is still running.
    case unknown
    /// `--run-task list` answered with a task list that matches this app's catalog.
    case supported(CLITaskListing)
    /// The CLI rejected `--run-task` (exit 1, "Unknown option").
    case unsupported(installedVersion: String?)
    /// `--run-task list` works, but the list differs from `TaskID` — the
    /// sentences come from `CLITaskListing.drift`. Runs are still allowed.
    case incompatible(reasons: [String])

    var allowsRuns: Bool {
        switch self {
        case .supported, .incompatible: true
        case .unknown, .unsupported: false
        }
    }
}

/// Root view model: CLI location, interfaces, sidebar selection, terminal
/// session, run coordinator and the New Run sheet.
@MainActor
@Observable
final class AppModel {
    var selection: SidebarItem? = .runAudit

    private(set) var cli: CLIInstall?
    private(set) var cliVersion: String?
    private(set) var nonInteractiveSupport: NonInteractiveSupport = .unknown
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

    /// "Show log" on the Run Audit screen (persisted; see `isRunLogVisible`).
    var showRunLog: Bool = Defaults[.showRunLog] {
        didSet { Defaults[.showRunLog] = showRunLog }
    }

    /// Automation `--show-log`: forces the log open for a capture without writing
    /// the user's preference (the debug app shares the bundle identifier, and so the
    /// defaults domain, with the installed one).
    var forceRunLogForAutomation = false

    /// The terminal pane is visible under the progress/results: by preference, for a
    /// capture, or because sudo is waiting for the password — the one moment the user
    /// has to type into it.
    var isRunLogVisible: Bool {
        showRunLog || forceRunLogForAutomation || runCoordinator.phase == .awaitingPassword
    }

    let terminal = TerminalSession()
    let runBrowser = RunBrowserModel()
    let runCoordinator = RunCoordinator()

    // MARK: Privileged helper (contract 07 §5)

    let helperInstaller = HelperInstaller()
    let helperClient = HelperClient()
    /// The administrator credential for helper runs on a user-owned tool chain (§11.2).
    let authorizationSession = AuthorizationSession()

    /// Settings → Privileges. `.helper` only takes effect while `isHelperReady`.
    var privilegeMode: PrivilegeMode = Defaults[.privilegeMode] {
        didSet { Defaults[.privilegeMode] = privilegeMode }
    }

    /// How often the helper route asks for administrator authentication. A credential
    /// held for another right than the new cadence's cannot serve the next run (it
    /// would be locked then anyway), so it is dropped now and Settings stops showing
    /// "Authenticated at" for it — unless a dialog is up, which stays undisturbed.
    var helperAuthenticationCadence: AuthorizationSession.Cadence = Defaults[.helperAuthenticationCadence] {
        didSet {
            Defaults[.helperAuthenticationCadence] = helperAuthenticationCadence
            if let held = authorizationSession.heldRight, held != helperAuthenticationCadence.right,
               !authorizationSession.isAuthenticating {
                authorizationSession.lock()
            }
        }
    }

    /// The helper's verdict on its tool chain (`toolchainTrust`), refreshed with every
    /// helper check. Advisory: it decides whether the dialog is shown *before* the
    /// request; the helper judges again when it receives the run (S1).
    enum HelperToolchain: Equatable {
        case unknown
        case trusted
        /// The `untrustedToolchain` description: a run needs administrator authentication.
        case untrusted(String)
        /// A refusal no authentication clears (required tool missing from the root search
        /// path, relative PATH entry): the helper cannot run the CLI; no dialog is shown.
        case unusable(String)
    }

    private(set) var helperToolchain: HelperToolchain = .unknown

    /// Result of the last helper check (`refreshHelper()`).
    enum HelperCheck: Equatable {
        case unknown
        case checking
        /// SMAppService status is not `.enabled`; no XPC attempted.
        case notEnabled
        case ready(HelperClient.VersionInfo)
        /// Answers, but with another protocol version.
        case incompatible(HelperClient.VersionInfo)
        case unreachable(String)
    }

    private(set) var helperCheck: HelperCheck = .unknown

    /// Verification only (`--assume-helper-route`): the New Run sheet applies
    /// the helper-route rules (Task 17 needs a CoreWLAN scan) even though the
    /// helper is not enabled on this Mac. SMAppService status cannot be faked,
    /// so this is the only way to exercise that branch without an approved
    /// helper. It never loosens anything: it only adds a sheet problem.
    var assumeHelperRouteForAutomation = false

    /// True once the user asked for the interactive CLI (button or Terminal
    /// menu). The session never starts on its own any more: the pane is
    /// shared with non-interactive runs.
    var userRequestedInteractiveCLI = false

    /// Presents the New Run / Continue Run sheet while non-nil.
    var newRunSheet: NewRunSheetRequest?

    /// Presents the Setup & Permissions sheet (`--setup`, the app menu, or the first
    /// launch of a build — see `SetupModel`).
    var setupPresented = false

    /// State of the Setup & Permissions sheet (Location, Local Network, the one-off
    /// authentication); reads this model for the CLI and the helper.
    let setup = SetupModel()

    /// A run or report build that is waiting for the user to confirm ending
    /// the interactive CLI session (`startRun` / `rebuildReport` set it; the
    /// sheet or `ContentView` shows the dialog). The SSH password of a Task 19
    /// run is held here only until the dialog is answered.
    enum PendingLaunch: Equatable {
        case run(RunTaskRequest, sshPassword: String?)
        case report(BuildReportRequest)
        case delete(DeleteRunRequest)
    }

    var pendingLaunch: PendingLaunch?

    /// Set by `--output-dir` (automation / fixtures); otherwise the CLI's `output/` is browsed.
    var outputDirectoryOverride: URL?

    init() {
        runCoordinator.model = self
        setup.model = self
    }

    /// Opens the Setup & Permissions sheet. One sheet at a time on the document
    /// window: from the menu the New Run sheet is closed first and the present is
    /// deferred until its dismissal has animated out (presenting in the same turn has
    /// been seen to drop the second sheet while leaving `setupPresented` set). The
    /// automatic paths (`--setup`, first launch of a build) never discard a sheet the
    /// user has opened — the Setup sheet comes back on the next launch instead.
    func presentSetup(automatic: Bool = false) {
        guard !setupPresented else { return }
        guard newRunSheet != nil else {
            setupPresented = true
            return
        }
        if automatic { return }
        newRunSheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard newRunSheet == nil else { return }
            setupPresented = true
        }
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

    /// Re-detects the CLI install, its version, whether it supports
    /// non-interactive runs, and the interface list.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let override = cliAppRootOverride
        let detected = CLIInstall.detect(overrideAppRoot: override.isEmpty ? nil : override)
        cli = detected
        if detected == nil { nonInteractiveSupport = .unknown }

        async let interfaceList = NetworkInterfaces.list()
        async let defaultRoute = NetworkInterfaces.defaultRouteInterface()
        async let version: String? = {
            guard let detected else { return nil }
            return await CLIVersionProbe.version(of: detected)
        }()
        async let support: NonInteractiveSupport = {
            guard let detected else { return .unknown }
            return await Self.probeNonInteractiveSupport(of: detected)
        }()

        interfaces = await interfaceList
        defaultRouteInterface = await defaultRoute
        cliVersion = await version
        var probed = await support
        if case .unsupported = probed {
            probed = .unsupported(installedVersion: cliVersion)
        }
        nonInteractiveSupport = probed

        if selectedInterface.isEmpty || !interfaces.contains(where: { $0.device == selectedInterface }) {
            selectedInterface = defaultRouteInterface ?? interfaces.first?.device ?? ""
        }

        lastRefresh = .now
        launchTerminalIfNeeded()
        configureRunBrowser()
        await refreshHelper()
    }

    // MARK: Non-interactive capability gate

    /// `<launcher> --run-task list`: exit 0 and a JSON task listing on stdout
    /// when the CLI supports non-interactive mode; "Unknown option" and exit 1
    /// otherwise. The listing is compared with `TaskID` so a CLI that names or
    /// files its tasks differently is reported (runs still allowed).
    nonisolated static func probeNonInteractiveSupport(of install: CLIInstall) async -> NonInteractiveSupport {
        let command = install.launchCommand
        guard let result = try? await ProcessRunner.run(command.executable, command.arguments + ["--run-task", "list"]),
              result.succeeded,
              let listing = try? CLITaskListing.parse(Data(result.stdout.utf8)) else {
            return .unsupported(installedVersion: nil)
        }
        let drift = listing.drift(against: TaskID.allCases)
        return drift.isEmpty ? .supported(listing) : .incompatible(reasons: drift)
    }

    /// Every control that starts a run or rebuilds a report: the CLI is
    /// installed, it supports non-interactive mode, and nothing is running.
    var canStartRuns: Bool {
        cli != nil && nonInteractiveSupport.allowsRuns && !runCoordinator.isActive
    }

    /// Why runs are gated by the installed CLI (nil when they are not). Shown
    /// inline wherever a run could start, and in Settings.
    var nonInteractiveGateMessage: String? {
        guard cli != nil, case .unsupported(let version) = nonInteractiveSupport else { return nil }
        return Self.gateMessage(installedVersion: version)
    }

    static func gateMessage(installedVersion: String?) -> String {
        "The installed command-line tool (\(installedVersion ?? "unknown version")) does not support non-interactive runs. Update it with `sudo ./install.sh` from the repository, then Settings → Re-detect."
    }

    /// Sentences describing how the CLI's task list differs from this app
    /// (empty unless `nonInteractiveSupport` is `.incompatible`).
    var taskListDrift: [String] {
        if case .incompatible(let reasons) = nonInteractiveSupport { return reasons }
        return []
    }

    // MARK: Delete-run capability gate

    /// The first engine version with `--delete-run`.
    static let deleteRunMinimumCLIVersion = "v1.2.251"

    /// The installed CLI's version as the app knows it: `--version`, or the
    /// `version` field of the `--run-task list` capability JSON.
    var knownCLIVersion: String? {
        if let cliVersion { return cliVersion }
        if case .supported(let listing) = nonInteractiveSupport { return listing.version }
        return nil
    }

    /// `--delete-run` exists only from v1.2.251 (numeric dotted compare); an older
    /// CLI would reject the flag as a usage error after the password was typed.
    var cliSupportsDeleteRun: Bool {
        guard let version = knownCLIVersion else { return false }
        return CLIVersionProbe.compare(version, Self.deleteRunMinimumCLIVersion) != .orderedAscending
    }

    /// Why Delete Run… is disabled (nil when it is not).
    var deleteRunGateMessage: String? {
        if let gate = nonInteractiveGateMessage { return gate }
        guard cli != nil, !cliSupportsDeleteRun else { return nil }
        return "Deleting runs needs command-line tool \(Self.deleteRunMinimumCLIVersion) or newer — update it with `sudo lss-network-tools --update`."
    }

    /// Delete Run… (Previous Runs): every run control's gate plus the engine version.
    var canDeleteRuns: Bool {
        canStartRuns && cliSupportsDeleteRun
    }

    // MARK: Privileged helper

    /// Enabled in launchd and answering `version()` with this app's protocol.
    var isHelperReady: Bool {
        guard helperInstaller.status == .enabled, case .ready = helperCheck else { return false }
        return true
    }

    /// True when a run started now would be offered to the privileged helper:
    /// the mode is `.helper` and the helper is enabled with a protocol this app
    /// speaks. `RunCoordinator` re-checks `version()` as the run starts, so a
    /// helper that was unreachable at the last check may still answer then —
    /// hence this is "would be offered", not `isHelperReady`. The New Run
    /// sheet uses it for the rules of the helper route (Task 17 needs a
    /// CoreWLAN scan: the helper cannot open LSS-WiFiScan.app).
    var wouldRouteRunsThroughHelper: Bool {
        if assumeHelperRouteForAutomation { return true }
        guard privilegeMode == .helper, helperInstaller.status == .enabled else { return false }
        if case .incompatible = helperCheck { return false }
        return true
    }

    /// Re-reads the SMAppService status and, when enabled, pings the helper; after a
    /// compatible answer it also asks for the helper's tool-chain verdict.
    func refreshHelper() async {
        helperInstaller.refresh()
        guard helperInstaller.status == .enabled else {
            helperCheck = .notEnabled
            helperToolchain = .unknown
            return
        }
        helperCheck = .checking
        do {
            let info = try await helperClient.version()
            helperCheck = info.isCompatible ? .ready(info) : .incompatible(info)
        } catch {
            helperCheck = .unreachable(error.localizedDescription)
            helperToolchain = .unknown
            return
        }
        guard case .ready = helperCheck else {
            helperToolchain = .unknown
            return
        }
        if let trust = try? await helperClient.toolchainTrust() {
            switch trust {
            case .trusted: helperToolchain = .trusted
            case .untrusted(let reason): helperToolchain = .untrusted(reason)
            case .unusable(let reason): helperToolchain = .unusable(reason)
            }
        } else {
            helperToolchain = .unknown
        }
    }

    /// The authorization to send with a helper run: nil when the helper said its tool
    /// chain is root-owned, when it said the chain cannot run at all (no dialog can
    /// help), or when its verdict is unknown and nothing forces a dialog (the helper
    /// refuses with `authorizationRequired` if it disagrees, and the coordinator calls
    /// again with `forceInteraction`). With `forceInteraction` the helper has just
    /// demanded authentication, so its verdict overrides the app's advisory view (S1)
    /// and the dialog is shown whatever `helperToolchain` says. The right the form was
    /// obtained for is `helperAuthenticationCadence.right`; send it with the request.
    func authorizationForHelperRun(forceInteraction: Bool = false) async throws -> Data? {
        if !forceInteraction {
            switch helperToolchain {
            case .trusted, .unknown, .unusable: return nil
            case .untrusted: break
            }
        }
        return try await authorizationSession.externalForm(for: helperAuthenticationCadence)
    }

    /// Called by `RunCoordinator` as a run starts: true when it should go through
    /// the helper (chosen in Settings, enabled, answering with the right protocol).
    func prepareHelperForRun() async -> Bool {
        guard privilegeMode == .helper else { return false }
        await refreshHelper()
        return isHelperReady
    }

    /// `SMAppService.register()`; opens Login Items when macOS wants approval.
    func registerHelper() {
        helperClient.reset()
        if case .needsApproval = helperInstaller.register() {
            helperInstaller.openLoginItems()
        }
        Task { await refreshHelper() }
    }

    func unregisterHelper() {
        helperClient.reset()
        // A credential kept for a helper that is gone has no use; drop it.
        authorizationSession.lock()
        helperInstaller.unregister()
        Task { await refreshHelper() }
    }

    /// Registered, but not usable from this copy: the rebuilt-app case (launchd says
    /// enabled, the helper does not answer because the registration still points at an
    /// earlier ad-hoc build) and an answering helper of another protocol version (an
    /// older copy at its path). Settings and the Setup sheet then offer Re-register.
    var helperNeedsReregistration: Bool {
        guard helperInstaller.status == .enabled else { return false }
        switch helperCheck {
        case .unreachable, .incompatible: return true
        default: return false
        }
    }

    private(set) var isReregisteringHelper = false

    /// Unregister, then register from this copy of the app (opening Login Items when
    /// macOS wants the approval again), then check. Returns the register outcome.
    @discardableResult
    func reregisterHelper() async -> HelperInstaller.RegisterOutcome {
        isReregisteringHelper = true
        defer { isReregisteringHelper = false }
        helperClient.reset()
        authorizationSession.lock()
        let unregisterError = helperInstaller.unregister() ? nil : helperInstaller.lastError
        // launchd takes a moment to forget the old registration; registering in the
        // same turn has been seen to report the stale status.
        try? await Task.sleep(for: .milliseconds(500))
        let outcome = helperInstaller.register()
        if case .needsApproval = outcome {
            helperInstaller.openLoginItems()
        }
        if let unregisterError, case .enabled = outcome {
            // register() saw the still-enabled status and cleared lastError; without
            // this the sheet would look exactly as before the click.
            helperInstaller.recordError("Unregister failed, so the registration may still point at the old copy: \(unregisterError)")
        }
        await refreshHelper()
        return outcome
    }

    /// `chmod 0644` on a run's `*.json` files through the helper, then reloads the
    /// browser so the files decode. Returns the number of files changed.
    func repairPermissions(of runDirectory: URL) async throws -> Int {
        let changed = try await helperClient.repair(runDirectory: runDirectory.path(percentEncoded: false))
        await runBrowser.refresh()
        return changed
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
            terminal.launchInteractive(
                executable: "/usr/bin/sudo",
                arguments: [command.executable] + command.arguments,
                environment: environment
            )
        } else {
            terminal.launchInteractive(executable: "/bin/zsh", arguments: ["-l"], environment: environment)
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

    /// The interactive CLI session is running in the pane (and not a
    /// non-interactive run): starting a run now would SIGTERM it.
    var interactiveSessionWouldBeEnded: Bool {
        terminal.state == .running && !runCoordinator.isActive
    }

    // MARK: New Run sheet

    /// Prefilled draft: interface from the run's manifest (continue) or the
    /// toolbar, last client/location, Prepared-by and Skip-PDF defaults, and
    /// the task selection (a single preselected task, pending audit tasks of a
    /// continued audit run, else the full audit). A manifest interface that is
    /// not present on this Mac now falls back to the toolbar interface, and the
    /// draft records which one was replaced so the sheet can say so.
    func makeDraft(task: TaskID?, existingRun: RunSummary?) -> RunDraft {
        var draft = RunDraft()
        draft.existingRun = existingRun
        let manifestInterface = existingRun?.interface.flatMap { $0.isEmpty ? nil : $0 }
        if let manifestInterface, !interfaces.contains(where: { $0.device == manifestInterface }) {
            draft.interface = selectedInterface
            draft.interfaceMissingFromRun = manifestInterface
        } else {
            draft.interface = manifestInterface ?? selectedInterface
        }
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

    /// Persists the sheet's reusable values: the client and location of a new
    /// run. Prepared-by is a Settings default (its caption says so) and is not
    /// written back from the sheet — a one-off name on one run stays one-off.
    func rememberRunDefaults(from draft: RunDraft) {
        guard !draft.isContinuing else { return }
        Defaults[.lastClient] = draft.client.trimmed
        Defaults[.lastLocation] = draft.location.trimmed
    }

    /// Starts the run and shows its progress (the Run Audit screen, unless a
    /// task screen — which shows the same progress view — is already selected).
    /// While the interactive CLI session is running the start is parked in
    /// `pendingLaunch` until the user confirms ending it.
    func startRun(_ request: RunTaskRequest, sshPassword: String?) {
        let launch = PendingLaunch.run(request, sshPassword: sshPassword)
        if interactiveSessionWouldBeEnded {
            pendingLaunch = launch
        } else {
            perform(launch)
        }
    }

    /// `--build-report <run-dir>` for a run in the browser. Returns a problem
    /// sentence instead of launching when the run directory no longer exists
    /// (the browser is refreshed so the stale entry disappears); parks the
    /// launch in `pendingLaunch` while the interactive session is running.
    @discardableResult
    func rebuildReport(for run: RunSummary) -> String? {
        let path = run.directory.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            Task { await runBrowser.refresh() }
            return "The run directory no longer exists: \(path)"
        }
        let request = BuildReportRequest(
            runDirectory: run.directory,
            preparedBy: preparedBy.isEmpty ? nil : preparedBy,
            skipPDF: skipPDFByDefault
        )
        let launch = PendingLaunch.report(request)
        if interactiveSessionWouldBeEnded {
            pendingLaunch = launch
        } else {
            perform(launch)
        }
        return nil
    }

    /// `--delete-run <run-dir>` for a run in the browser, through the engine on the
    /// selected privilege route (the app cannot remove root-owned directories
    /// itself). Mirrors `rebuildReport(for:)`: a problem sentence instead of a launch
    /// when the directory is gone or the installed CLI predates the flag; parked in
    /// `pendingLaunch` while the interactive session is running.
    @discardableResult
    func deleteRun(_ run: RunSummary) -> String? {
        if let gate = deleteRunGateMessage { return gate }
        let path = run.directory.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            Task { await runBrowser.refresh() }
            return "The run directory no longer exists: \(path)"
        }
        let launch = PendingLaunch.delete(DeleteRunRequest(runDirectory: run.directory))
        if interactiveSessionWouldBeEnded {
            pendingLaunch = launch
        } else {
            perform(launch)
        }
        return nil
    }

    /// Set while a deletion started from Previous Runs moved the window to the Run
    /// Audit screen (sudo route: the password is typed in the pane there); the
    /// screen goes back once the run directory is gone.
    @ObservationIgnored private var returnToPreviousRunsAfterDeletion = false

    /// Called by the coordinator when sudo waits for the password of a deletion: the
    /// pane that takes it is on the Run Audit screen.
    func showRunAuditForPassword() {
        guard selection != .runAudit else { return }
        if selection == .previousRuns { returnToPreviousRunsAfterDeletion = true }
        selection = .runAudit
    }

    /// The engine removed the directory and the coordinator went back to idle.
    func runDeletionDidSucceed() {
        if returnToPreviousRunsAfterDeletion {
            returnToPreviousRunsAfterDeletion = false
            if selection == .runAudit { selection = .previousRuns }
        }
        Task { await runBrowser.refresh() }
    }

    /// "End Session and Start" in the confirmation dialog.
    func confirmPendingLaunch() {
        guard let launch = pendingLaunch else { return }
        pendingLaunch = nil
        perform(launch)
    }

    /// Cancel in the confirmation dialog: nothing starts, the session goes on.
    func cancelPendingLaunch() {
        pendingLaunch = nil
    }

    private func perform(_ launch: PendingLaunch) {
        switch launch {
        case .run(let request, let sshPassword):
            runCoordinator.start(request, sshPassword: sshPassword)
            switch selection {
            case .runAudit?, .task?: break
            default: selection = .runAudit
            }
        case .report(let request):
            runCoordinator.buildReport(request)
            selection = .runAudit
        case .delete(let request):
            // Through the helper the deletion runs in the background and Previous Runs
            // shows "Deleting…"; with sudo the password must be typed in the pane, so
            // the Run Audit screen (whose log opens for the prompt) is shown now.
            returnToPreviousRunsAfterDeletion = false
            runCoordinator.deleteRun(request)
            if !wouldRouteRunsThroughHelper {
                showRunAuditForPassword()
            }
        }
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
