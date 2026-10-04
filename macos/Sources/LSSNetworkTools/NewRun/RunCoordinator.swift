import Foundation
import Observation
import LSSCore
import LSSXPC

/// Lifecycle of one non-interactive CLI invocation (contract §3.2).
enum RunPhase: Equatable {
    case idle
    /// sudo has been launched; no `hello` yet.
    case launching
    /// No `hello` within 3 s and the pty showed a password prompt.
    case awaitingPassword
    /// Helper route: the standard macOS administrator-authentication dialog is expected
    /// or up (`AppModel.authorizationForHelperRun`); nothing has been sent yet.
    case awaitingAuthentication
    /// `hello` received; tasks are running.
    case running
    /// `bye` received or the process exited. `nil` when the exit code is not one the contract defines.
    case finished(CLIExitCode?)
    /// argv could not be built, the CLI is missing, or sudo never started the tool.
    case failedToLaunch(String)
}

/// One task of the current run as the progress list shows it.
struct TaskProgress: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case running
        case done(status: String)
        case failed(status: String)
        case skipped
    }

    let task: TaskID
    var state: State = .pending
    /// Latest `task_stage` label, or the "Stage N:" heuristic on human lines.
    var stage: String?
    /// New JSON files reported by `task_done`.
    var jsonFiles: [String] = []

    var id: TaskID { task }
}

/// Builds argv for a `RunTaskRequest` / `BuildReportRequest`, launches it, and
/// turns the output bytes into phase/task state through `ProgressLineParser`.
///
/// Two routes (contract 07 §5):
/// * **helper** — when Settings → Privileges selects the privileged helper, it is
///   enabled and `version()` answers with this app's protocol: `HelperClient.run`
///   streams the child's output through a pipe; the bytes are rendered in the
///   terminal pane (LF → CRLF, as a pty would) and parsed exactly like pty bytes.
///   No sudo prompt, so `.awaitingPassword` never happens; on a user-owned tool
///   chain the standard macOS authentication dialog runs first
///   (`AppModel.authorizationForHelperRun`, contract §11.2; phase
///   `.awaitingAuthentication` while it can be up), and a run the helper answers
///   with `authorizationRequired` is sent once more after a forced dialog. Under the
///   "Every run" cadence the credential is locked as soon as the request is answered.
/// * **terminal** — `sudo <wrapper> …` in the shared `TerminalSession` (M3,
///   unchanged): the pane is the log and where the sudo password is typed.
///
/// A run that wanted the helper but found it unavailable falls back to the
/// terminal route with a warning; so does Task 17 without a CoreWLAN scan,
/// which needs the engine's own `LSS-WiFiScan.app` and therefore a logged-in
/// user session the helper does not have.
///
/// Every run gets a fresh secret (`ProgressLineParser.makeToken()`), handed to
/// the engine as `LSS_PROGRESS_TOKEN` (preserved through sudo, or set by the
/// helper), so only `@@LSS <token> {…}` lines count as events: device-supplied
/// text echoed by the engine cannot forge progress.
@MainActor
@Observable
final class RunCoordinator {
    enum Mode: Equatable {
        case run(RunTaskRequest)
        case report(BuildReportRequest)
        /// `simulate(stream:interval:)` — a fixture replayed through the parser, no process.
        case simulation
    }

    static let logCapacity = 2_000
    static let passwordGracePeriod: Duration = .seconds(3)

    private(set) var phase: RunPhase = .idle
    private(set) var mode: Mode?
    private(set) var tasks: [TaskProgress] = []
    private(set) var runDirectory: URL?
    private(set) var reportTXT: String?
    private(set) var reportPDF: String?
    private(set) var pdfFailure: String?
    private(set) var lastError: (code: String?, message: String?)?
    private(set) var warnings: [(code: String?, message: String?)] = []
    /// Non-progress lines (ANSI-stripped), capped at `logCapacity`.
    private(set) var log: [String] = []
    private(set) var exitCode: Int32?
    private(set) var cliVersion: String?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?

    /// Set by `AppModel` after both exist. Supplies the terminal, the CLI
    /// location and the run browser to refresh.
    @ObservationIgnored weak var model: AppModel?

    @ObservationIgnored private var parser = ProgressLineParser()
    @ObservationIgnored private var sawHello = false
    @ObservationIgnored private var sawPasswordPrompt = false
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var currentTask: TaskID?
    @ObservationIgnored private var passwordTimer: Task<Void, Never>?
    @ObservationIgnored private var simulation: Task<Void, Never>?
    /// The deferred sudo launch of the terminal route (settle window); non-nil
    /// only between `launchProcess` and the moment the process starts.
    @ObservationIgnored private var launchTask: Task<Void, Never>?

    /// True while (and after) the current run goes through the privileged helper.
    private(set) var usesHelper = false

    private enum Route { case none, deciding, terminal, helper }
    @ObservationIgnored private var route: Route = .none
    /// `HelperRunRequest.token` of the helper run in flight (for `cancel`).
    @ObservationIgnored private var helperToken: String?
    @ObservationIgnored private var helperTask: Task<Void, Never>?
    /// False once the interactive CLI took the pane back from a helper run.
    @ObservationIgnored private var helperOwnsTerminal = false
    /// Set by `releaseTerminal` while a helper run is still winding down.
    @ObservationIgnored private var dismissWhenFinished = false
    /// The previous byte rendered for a helper run was CR (LF → CRLF conversion).
    @ObservationIgnored private var terminalLastByteWasCR = false
    /// Bumped by `reset`; late callbacks of an earlier run compare against it.
    @ObservationIgnored private var generation = 0

    // MARK: Derived state

    var request: RunTaskRequest? {
        if case .run(let request) = mode { return request }
        return nil
    }

    var isActive: Bool {
        switch phase {
        case .launching, .awaitingPassword, .awaitingAuthentication, .running: true
        case .idle, .finished, .failedToLaunch: false
        }
    }

    var isSimulating: Bool { mode == .simulation }

    var isBuildingReport: Bool {
        if case .report = mode { return true }
        return false
    }

    /// "Client — Location" for a new run, the run's title for a continued run.
    var title: String {
        switch mode {
        case .run(let request):
            switch request.context {
            case .newRun(let client, let location, _):
                let parts = [client, location].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return parts.isEmpty ? "New run" : parts.joined(separator: " — ")
            case .existingRun(let directory):
                return browserTitle(for: directory) ?? directory.lastPathComponent
            }
        case .report(let request):
            return "Rebuild report — \(browserTitle(for: request.runDirectory) ?? request.runDirectory.lastPathComponent)"
        case .simulation:
            return "Simulated run"
        case nil:
            return ""
        }
    }

    /// Second header line: what is being run and on which interface.
    var subtitle: String {
        switch mode {
        case .run(let request):
            var parts: [String] = []
            switch request.selection {
            case .fullAudit: parts.append("Full audit (tasks 1–12)")
            case .tasks(let ids):
                let sorted = Array(Set(ids)).sorted()
                parts.append(sorted.count == 1
                    ? "Task \(sorted[0].rawValue) — \(sorted[0].title)"
                    : "Tasks \(sorted.map { String($0.rawValue) }.joined(separator: ", "))")
            }
            if let interface = request.interface, !interface.isEmpty { parts.append("interface \(interface)") }
            if case .existingRun = request.context { parts.append("continuing an existing run") }
            if let version = cliVersion { parts.append("CLI \(version)") }
            return parts.joined(separator: " · ")
        case .report(let request):
            return request.skipPDF ? "TXT report only" : "TXT and PDF report"
        case .simulation:
            return "Fixture stream replayed through the progress parser — no process is running"
        case nil:
            return ""
        }
    }

    var runningTask: TaskProgress? { tasks.first { $0.state == .running } }

    var completedTaskCount: Int {
        tasks.filter {
            switch $0.state {
            case .done, .failed, .skipped: true
            case .pending, .running: false
            }
        }.count
    }

    // MARK: Starting

    /// Builds argv, resets all progress state and launches the run — through the
    /// privileged helper when Settings selects it and it answers, otherwise as
    /// `sudo <wrapper> --run-task …` in the shared terminal. The SSH password and
    /// the per-run progress token travel only in the child's environment
    /// (`LSS_SSH_PASSWORD`, `LSS_PROGRESS_TOKEN`: preserved through sudo, or set
    /// by the helper). A run still in flight is cancelled first — while its
    /// helper token is still known — so no root child is orphaned.
    func start(_ request: RunTaskRequest, sshPassword: String?) {
        if isActive { cancel() }
        reset(mode: .run(request))
        let progressToken = ProgressLineParser.makeToken()
        parser = ProgressLineParser(token: progressToken)
        guard let model else { return }
        guard let cli = model.cli else {
            phase = .failedToLaunch("The command-line tool is not installed, so the run cannot start.")
            return
        }
        let arguments: [String]
        do {
            arguments = try ArgumentBuilder.arguments(for: request)
        } catch let problem as ArgumentBuilder.Problem {
            phase = .failedToLaunch(problem.description)
            return
        } catch {
            phase = .failedToLaunch(String(describing: error))
            return
        }
        // The wrapper exports the Homebrew-first PATH; without one the script
        // runs through /bin/bash, as `launchCommand` does for the interactive CLI.
        let launch = cli.launchCommand
        var preserved = ["LSS_PROGRESS_TOKEN"]
        if sshPassword != nil { preserved.append("LSS_SSH_PASSWORD") }
        let command = ArgumentBuilder.sudoCommand(
            wrapper: launch.executable,
            arguments: launch.arguments + arguments,
            preserveEnvironment: preserved
        )
        var environment = ProcessRunner.baseEnvironment
        environment["TERM_PROGRAM"] = "LSSNetworkTools"
        environment["LSS_PROGRESS_TOKEN"] = progressToken
        if let sshPassword { environment["LSS_SSH_PASSWORD"] = sshPassword }

        if case .existingRun(let directory) = request.context { runDirectory = directory }
        tasks = request.selection.taskIDs.map { TaskProgress(task: $0) }
        // Task 17 without a CoreWLAN scan opens the engine's LSS-WiFiScan.app, which
        // needs the logged-in user's session (SUDO_USER); a launchd daemon has none
        // and the engine refuses with exit 2 — so that run always takes sudo.
        let needsLoginSession = request.requiresWireless && request.wireless?.scanJSON == nil
        launchPreferringHelper(arguments: arguments, sshPassword: sshPassword, progressToken: progressToken,
                               needsLoginSession: needsLoginSession) { [weak self] in
            self?.launchProcess(executable: command.executable, arguments: command.arguments, environment: environment)
        }
    }

    /// `sudo <wrapper> --build-report <run-dir> …`.
    func buildReport(_ request: BuildReportRequest) {
        if isActive { cancel() }
        reset(mode: .report(request))
        let progressToken = ProgressLineParser.makeToken()
        parser = ProgressLineParser(token: progressToken)
        guard let model else { return }
        guard let cli = model.cli else {
            phase = .failedToLaunch("The command-line tool is not installed, so the report cannot be rebuilt.")
            return
        }
        let arguments: [String]
        do {
            arguments = try ArgumentBuilder.arguments(for: request)
        } catch let problem as ArgumentBuilder.Problem {
            phase = .failedToLaunch(problem.description)
            return
        } catch {
            phase = .failedToLaunch(String(describing: error))
            return
        }
        let launch = cli.launchCommand
        let command = ArgumentBuilder.sudoCommand(wrapper: launch.executable, arguments: launch.arguments + arguments,
                                                  preserveEnvironment: ["LSS_PROGRESS_TOKEN"])
        var environment = ProcessRunner.baseEnvironment
        environment["TERM_PROGRAM"] = "LSSNetworkTools"
        environment["LSS_PROGRESS_TOKEN"] = progressToken
        runDirectory = request.runDirectory
        launchPreferringHelper(arguments: arguments, sshPassword: nil, progressToken: progressToken, needsLoginSession: false) { [weak self] in
            self?.launchProcess(executable: command.executable, arguments: command.arguments, environment: environment)
        }
    }

    /// Terminates the process (sudo relays SIGTERM; the script's INT/TERM trap
    /// exits 130 and its EXIT trap kills background tools). On the helper route
    /// the helper sends SIGTERM (SIGKILL after 5 s) and the run ends with its reply.
    /// When there is no child yet to receive a signal — the helper is still being
    /// asked for its version, or sudo is in its settle window — the run ends here,
    /// as `.finished(.interrupted)`, and the deferred launch never happens.
    func cancel() {
        guard isActive else { return }
        cancelRequested = true
        if let simulation {
            simulation.cancel()
            self.simulation = nil
            finish(exitCode: CLIExitCode.interrupted.rawValue)
            return
        }
        switch route {
        case .deciding:
            // Still asking the helper for its version: nothing has started.
            helperTask?.cancel()
            helperTask = nil
            route = .none
            finish(exitCode: CLIExitCode.interrupted.rawValue)
        case .helper:
            if let token = helperToken, let client = model?.helperClient {
                // The run ends with the helper's reply (handleProcessExit). A cancel the
                // helper receives before the run is reserved is recorded there and the
                // run refused with the `cancelled` code; `false` means the token is
                // unknown to this user's connection, so ask once more a moment later.
                let captured = generation
                Task { [weak self] in
                    if await client.cancel(token: token) { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, self.generation == captured, self.isActive, self.helperToken == token else { return }
                    _ = await client.cancel(token: token)
                }
            } else {
                // Nothing sent yet: the helper is still being prepared, or the
                // authentication dialog is up. The app cannot dismiss that dialog; its
                // eventual answer is discarded and the credential destroyed (`lock()`
                // defers the free until the dialog has returned).
                if let session = model?.authorizationSession, session.isAuthenticating { session.lock() }
                finish(exitCode: CLIExitCode.interrupted.rawValue)
            }
        case .terminal, .none:
            if let launchTask {
                // Settle window: sudo has not been started, so there is nothing to signal.
                launchTask.cancel()
                self.launchTask = nil
                finish(exitCode: CLIExitCode.interrupted.rawValue)
            } else if let terminal = model?.terminal, terminal.state == .running {
                // → onProcessExit → handleProcessExit → finish; the guard below only
                // matters if the tap was detached in between.
                terminal.terminate()
                if isActive { finish(exitCode: CLIExitCode.interrupted.rawValue) }
            } else {
                finish(exitCode: CLIExitCode.interrupted.rawValue)
            }
        }
    }

    /// Returns to the idle state once a run has ended, giving the pane back to
    /// the interactive CLI placeholder.
    func dismiss() {
        guard !isActive else { return }
        detach()
        passwordTimer?.cancel()
        passwordTimer = nil
        mode = nil
        phase = .idle
    }

    /// Called before the interactive CLI takes over the terminal: stops any
    /// run and stops interpreting the stream.
    func releaseTerminal() {
        helperOwnsTerminal = false
        if isActive { cancel() }
        // A helper run ends with the helper's reply, after the pane changed hands.
        if isActive { dismissWhenFinished = true }
        dismiss()
    }

    /// Replays a fixture stream through the same parsing path, one line per
    /// `interval`, without launching a process (automation, previews).
    func simulate(stream: Data, interval: Duration) {
        if isActive { cancel() }
        detach()
        reset(mode: .simulation)
        tasks = TaskID.auditTasks.map { TaskProgress(task: $0) }
        phase = .launching
        startedAt = .now
        let lines = stream.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        simulation = Task { [weak self] in
            for line in lines {
                guard let self, !Task.isCancelled else { return }
                var chunk = Array(line)
                chunk.append(UInt8(ascii: "\n"))
                // The pane shows the replayed stream exactly as a pty would.
                self.model?.terminal.display(chunk[...])
                self.consume(chunk[...])
                if case .finished = self.phase { break }
                try? await Task.sleep(for: interval)
            }
            guard let self, !Task.isCancelled else { return }
            self.simulation = nil
            if self.isActive { self.handleProcessExit(code: nil) }
        }
    }

    // MARK: Process plumbing

    /// The helper route when the user chose it and it is enabled; the terminal
    /// route otherwise, when the helper does not answer `version()`, or when the
    /// run needs the logged-in user's session (`needsLoginSession`: Task 17
    /// without a CoreWLAN scan).
    private func launchPreferringHelper(arguments: [String], sshPassword: String?, progressToken: String,
                                        needsLoginSession: Bool, viaTerminal: @escaping @MainActor () -> Void) {
        guard let model, model.privilegeMode == .helper else {
            viaTerminal()
            return
        }
        if needsLoginSession {
            warnings.append((code: "task_17_needs_sudo", message: "Task 17 without a CoreWLAN scan needs the engine's own Wi-Fi helper, which the privileged helper cannot open; using sudo in the terminal pane."))
            viaTerminal()
            return
        }
        model.helperInstaller.refresh()
        guard model.helperInstaller.status == .enabled else {
            warnings.append((code: "helper_not_enabled", message: "The privileged helper is not enabled (Settings → Privileges), so this run uses sudo in the terminal pane."))
            viaTerminal()
            return
        }
        route = .deciding
        phase = .launching
        startedAt = .now
        let generation = self.generation
        helperTask = Task { [weak self] in
            let ready = await model.prepareHelperForRun()
            guard let self, self.generation == generation, self.route == .deciding else { return }
            self.helperTask = nil
            if ready {
                await self.runViaHelper(arguments: arguments, sshPassword: sshPassword, progressToken: progressToken, generation: generation)
            } else {
                self.route = .none
                self.warnings.append((code: "helper_unavailable", message: "The privileged helper did not answer, so this run uses sudo in the terminal pane."))
                viaTerminal()
            }
        }
    }

    private func launchProcess(executable: String, arguments: [String], environment: [String: String]) {
        guard let model else { return }
        route = .terminal
        let terminal = model.terminal
        // The pane now belongs to the run; the interactive CLI must not restart on its own.
        model.userRequestedInteractiveCLI = false
        detach()
        // A previous pty session (the interactive CLI, or a run `cancel()` just
        // terminated) needs a moment to tear down before the view is reused.
        let needsSettle = terminal.state != .idle
        if terminal.state == .running { terminal.terminate() }
        attach(to: terminal)
        phase = .launching
        startedAt = .now
        let captured = generation
        launchTask?.cancel()
        launchTask = Task { [weak self] in
            if needsSettle { try? await Task.sleep(for: .milliseconds(250)) }
            // A cancel or a new run during the settle window must not launch sudo.
            guard let self, !Task.isCancelled, self.generation == captured,
                  self.phase == .launching, !self.cancelRequested else { return }
            self.launchTask = nil
            terminal.launch(executable: executable, arguments: arguments, environment: environment)
            self.startPasswordTimer()
        }
    }

    private func attach(to terminal: TerminalSession) {
        terminal.outputTap = { [weak self] slice in self?.consume(slice) }
        terminal.onProcessExit = { [weak self] code in self?.handleProcessExit(code: code) }
    }

    private func detach() {
        model?.terminal.outputTap = nil
        model?.terminal.onProcessExit = nil
    }

    private func startPasswordTimer() {
        passwordTimer?.cancel()
        passwordTimer = Task { [weak self] in
            try? await Task.sleep(for: RunCoordinator.passwordGracePeriod)
            guard !Task.isCancelled else { return }
            self?.evaluatePasswordPrompt()
        }
    }

    /// `.awaitingPassword` once the grace period has passed without `hello`
    /// and the pty showed sudo's prompt.
    private func evaluatePasswordPrompt() {
        guard phase == .launching, sawPasswordPrompt, !sawHello, let startedAt else { return }
        let elapsed = Duration.seconds(Date.now.timeIntervalSince(startedAt))
        if elapsed >= RunCoordinator.passwordGracePeriod {
            phase = .awaitingPassword
        }
    }

    private func reset(mode: Mode) {
        passwordTimer?.cancel()
        passwordTimer = nil
        simulation?.cancel()
        simulation = nil
        launchTask?.cancel()
        launchTask = nil
        generation += 1
        helperTask?.cancel()
        helperTask = nil
        helperToken = nil
        helperOwnsTerminal = false
        dismissWhenFinished = false
        terminalLastByteWasCR = false
        route = .none
        usesHelper = false
        self.mode = mode
        parser = ProgressLineParser()
        sawHello = false
        sawPasswordPrompt = false
        cancelRequested = false
        currentTask = nil
        tasks = []
        runDirectory = nil
        reportTXT = nil
        reportPDF = nil
        pdfFailure = nil
        lastError = nil
        warnings = []
        log = []
        exitCode = nil
        cliVersion = nil
        startedAt = nil
        finishedAt = nil
        phase = .idle
    }

    // MARK: Stream handling

    private func consume(_ bytes: ArraySlice<UInt8>) {
        if !sawHello, !sawPasswordPrompt {
            // sudo's prompt ends without a newline, so look at the raw chunk
            // instead of waiting for a complete line.
            if String(decoding: bytes, as: UTF8.self).contains("assword") {
                sawPasswordPrompt = true
                evaluatePasswordPrompt()
            }
        }
        process(parser.feed(bytes))
    }

    private func process(_ output: ProgressLineParser.Output) {
        for event in output.events {
            handle(event)
        }
        for line in output.lines {
            appendLog(line)
            if let current = currentTask, let stage = ProgressLineParser.stageHeuristic(in: line) {
                setStage(stage, for: current)
            }
        }
    }

    private func handle(_ event: ProgressEvent) {
        switch event.kind {
        case .hello(let version, _, let ids):
            sawHello = true
            cliVersion = version
            passwordTimer?.cancel()
            let resolved = ids.compactMap(TaskID.init(rawValue:))
            if !resolved.isEmpty {
                tasks = resolved.map { TaskProgress(task: $0) }
            } else if isBuildingReport {
                tasks = []
            }
            if isActive { phase = .running }

        case .runDirectory(let path, _):
            runDirectory = URL(filePath: path, directoryHint: .isDirectory)
            refreshBrowser()

        case .taskStart(let id, _, _, _):
            guard let task = TaskID(rawValue: id) else { return }
            ensureTask(task)
            update(task) { $0.state = .running; $0.stage = nil }
            currentTask = task

        case .taskStage(let id, let stage, let label):
            guard let task = TaskID(rawValue: id) else { return }
            if let text = label ?? stage { setStage(text, for: task) }

        case .taskDone(let id, let status, _, let files):
            guard let task = TaskID(rawValue: id) else { return }
            ensureTask(task)
            update(task) { progress in
                progress.jsonFiles = files
                // The engine exits 1 for anything but these three statuses, so an
                // unknown or missing status is a failure, never "done".
                switch status {
                case "skipped": progress.state = .skipped
                case "success", "completed_with_warnings": progress.state = .done(status: status ?? "success")
                default: progress.state = .failed(status: status ?? "unknown")
                }
            }
            if currentTask == task { currentTask = nil }
            refreshBrowser()

        case .reportBuilt(let txt):
            reportTXT = txt
            refreshBrowser()

        case .pdfBuilt(let pdf):
            reportPDF = pdf
            pdfFailure = nil
            refreshBrowser()

        case .pdfFailed(let message):
            pdfFailure = message ?? "The PDF report could not be generated."

        case .warning(let code, let message):
            warnings.append((code, message))

        case .error(let code, let message, let tools):
            var text = message ?? code ?? "The command-line tool reported an error."
            if !tools.isEmpty { text += " (" + tools.joined(separator: ", ") + ")" }
            lastError = (code, text)

        case .bye(let code):
            finish(exitCode: code.flatMap { Int32(exactly: $0) })

        case .unknown(let name):
            appendLog("[unrecognised progress event “\(name)”]")
        }
    }

    private func handleProcessExit(code: Int32?) {
        guard isActive else { return }
        process(parser.flush())
        guard isActive else { return } // the flush may have delivered `bye`
        if !sawHello, !cancelRequested {
            // Nothing from the script itself: sudo refused the password, the
            // launcher is missing, or the tool predates non-interactive mode.
            let detail = code.map { " (exit code \($0))" } ?? ""
            passwordTimer?.cancel()
            exitCode = code
            finishedAt = .now
            if route == .helper {
                phase = .failedToLaunch("The command-line tool exited before it started\(detail). Check the output in the terminal pane: the installed CLI may not support non-interactive runs yet.")
            } else {
                phase = .failedToLaunch("The command-line tool did not start\(detail). Check the terminal output below: sudo may have rejected the password, or the installed CLI may not support non-interactive runs yet.")
            }
            return
        }
        finish(exitCode: code)
    }

    private func finish(exitCode code: Int32?) {
        guard isActive else { return }
        passwordTimer?.cancel()
        exitCode = code
        finishedAt = .now
        for index in tasks.indices where tasks[index].state == .running {
            tasks[index].state = .failed(status: cancelRequested ? "cancelled" : "interrupted")
        }
        currentTask = nil
        if cancelRequested {
            phase = .finished(.interrupted)
        } else {
            phase = .finished(code.flatMap(CLIExitCode.init(rawValue:)))
        }
        refreshBrowser()
    }

    // MARK: Helper route

    private func runViaHelper(arguments: [String], sshPassword: String?, progressToken: String, generation: Int) async {
        guard let model else { return }
        route = .helper
        usesHelper = true
        // The pane shows this run, as it would on the terminal route.
        let terminal = model.terminal
        model.userRequestedInteractiveCLI = false
        detach()
        if terminal.state == .running { terminal.terminate() }
        helperOwnsTerminal = true
        terminalLastByteWasCR = false
        terminal.display(ArraySlice(Array("\u{1b}[2J\u{1b}[H".utf8)))

        // Under "Every run" no credential outlives its run (S5): whichever way this
        // function ends, the ref is destroyed once the request has been answered. A
        // newer run has already locked (and re-prompted) for itself, hence the guard.
        defer {
            if self.generation == generation, model.helperAuthenticationCadence == .everyRun {
                model.authorizationSession.lock()
            }
        }

        // Authentication first (S5): on a user-owned tool chain the standard macOS
        // dialog runs before anything is sent; a cancel ends the run here, and a
        // `cancel()` while the dialog is up has already finished it (`isActive`).
        var authorization: Data?
        do {
            authorization = try await authenticate(model: model, forceInteraction: false, generation: generation)
        } catch {
            guard self.generation == generation, isActive else { return }
            failAuthentication(error)
            return
        }
        guard self.generation == generation, isActive else { return }
        displayHelperBanner(authenticated: authorization != nil, replacingPrevious: false)

        /// One request; nil when a newer run replaced this one meanwhile. The right
        /// travels with the form: credentials are per token, so the name is what makes
        /// the helper enforce the cadence's timeout rather than the longest one.
        func send(_ authorization: Data?) async -> Result<HelperClient.RunOutcome, Error>? {
            let request = HelperRunRequest(arguments: arguments, sshPassword: sshPassword, progressToken: progressToken,
                                           callerUID: getuid(), authorization: authorization,
                                           authorizationRight: authorization == nil ? nil : model.helperAuthenticationCadence.right)
            helperToken = request.token
            let outcome: Result<HelperClient.RunOutcome, Error>
            do {
                let result = try await model.helperClient.run(request) { [weak self] data in
                    self?.consumeHelperOutput(data, generation: generation)
                }
                outcome = .success(result)
            } catch {
                outcome = .failure(error)
            }
            guard self.generation == generation else { return nil }
            helperToken = nil
            return outcome
        }

        var outcome = await send(authorization)
        // The helper's verdict wins (S1): when it demands authentication although the
        // app expected none — or the held credential had expired — ask once, with a
        // dialog, and send the same run again under a fresh request token (the per-run
        // progress token and parser stay). A second `authorizationRequired` is a
        // refusal like any other.
        if case .success(.refused(let refusal))? = outcome,
           refusal.isClearedByAuthentication, isActive, !cancelRequested {
            do {
                authorization = try await authenticate(model: model, forceInteraction: true, generation: generation)
            } catch {
                guard self.generation == generation, isActive else { return }
                failAuthentication(error)
                return
            }
            guard self.generation == generation, isActive else { return }
            // The first banner promised "no password needed" (or the old credential);
            // the helper produced no output before refusing, so that line is still the
            // last one in the pane and is replaced rather than contradicted below.
            displayHelperBanner(authenticated: authorization != nil, replacingPrevious: true)
            outcome = await send(authorization)
        }
        guard let outcome else { return }
        switch outcome {
        case .success(.exited(let code)):
            handleProcessExit(code: code)
        case .success(.refused(let refusal)) where refusal.isCancellation:
            // Our cancel reached the helper before the run was reserved: nothing ran.
            finish(exitCode: CLIExitCode.interrupted.rawValue)
        case .success(.refused(let refusal)):
            let hint: String
            if refusal.isClearedByAuthentication {
                hint = " Authenticate when asked, or choose “sudo in the terminal pane” in Settings → Privileges."
            } else if refusal.isAuthorizationRefusal {
                hint = "" // `authorizationUnavailable`: the message already names the sudo route; no dialog can help.
            } else {
                hint = " Choose “sudo in the terminal pane” in Settings → Privileges to run it with sudo instead."
            }
            failHelperRun("The privileged helper refused this run: \(refusal.message)\(hint)")
        case .failure(let error):
            if sawHello {
                lastError = (code: "helper_connection", message: error.localizedDescription)
                finish(exitCode: nil)
            } else {
                failHelperRun(error.localizedDescription)
            }
        }
        if dismissWhenFinished {
            dismissWhenFinished = false
            dismiss()
        }
    }

    /// `AppModel.authorizationForHelperRun`, with the phase naming the dialog while one
    /// can be on screen: when the helper's advisory verdict is user-owned, or when the
    /// helper has just demanded authentication (`forceInteraction`). A cached credential
    /// makes the phase flicker for the silent probe only.
    private func authenticate(model: AppModel, forceInteraction: Bool, generation: Int) async throws -> Data? {
        var dialogExpected = forceInteraction
        if case .untrusted = model.helperToolchain { dialogExpected = true }
        if dialogExpected, phase == .launching { phase = .awaitingAuthentication }
        defer {
            if self.generation == generation, phase == .awaitingAuthentication { phase = .launching }
        }
        return try await model.authorizationForHelperRun(forceInteraction: forceInteraction)
    }

    /// One dim line at the top of the pane saying how this run got root. With
    /// `replacingPrevious` the previous banner (still the last line: the helper refused
    /// without output) is cleared first, so the pane never shows two of them.
    private func displayHelperBanner(authenticated: Bool, replacingPrevious: Bool) {
        let text = authenticated
            ? "— running through the privileged helper after administrator authentication —"
            : "— running through the privileged helper; no password needed —"
        let clear = replacingPrevious ? "\u{1b}[1A\u{1b}[2K\r" : ""
        model?.terminal.display(ArraySlice(Array("\(clear)\u{1b}[2m\(text)\u{1b}[0m\r\n".utf8)))
    }

    /// The dialog was dismissed or Authorization Services failed: nothing started.
    private func failAuthentication(_ error: Error) {
        if let failure = error as? AuthorizationSession.AuthorizationError, failure == .cancelled {
            failHelperRun("Administrator authentication was cancelled, so the run did not start.")
        } else {
            failHelperRun("Administrator authentication failed: \(error.localizedDescription)")
        }
    }

    /// Helper output: rendered in the pane (while the run still owns it) and parsed
    /// like pty bytes, minus the sudo-prompt heuristics.
    private func consumeHelperOutput(_ data: Data, generation: Int) {
        guard self.generation == generation, route == .helper else { return }
        let bytes = [UInt8](data)
        if helperOwnsTerminal, let terminal = model?.terminal {
            terminal.display(terminalBytes(bytes)[...])
        }
        guard isActive else { return }
        process(parser.feed(bytes))
    }

    /// A pipe carries bare LF; the terminal needs CRLF (a pty's ONLCR) or lines
    /// would staircase.
    private func terminalBytes(_ bytes: [UInt8]) -> [UInt8] {
        var converted: [UInt8] = []
        converted.reserveCapacity(bytes.count + bytes.count / 32 + 1)
        for byte in bytes {
            if byte == 0x0A, !terminalLastByteWasCR { converted.append(0x0D) }
            converted.append(byte)
            terminalLastByteWasCR = byte == 0x0D
        }
        return converted
    }

    private func failHelperRun(_ message: String) {
        guard isActive else { return }
        passwordTimer?.cancel()
        finishedAt = .now
        phase = .failedToLaunch(message)
        refreshBrowser()
    }

    // MARK: Helpers

    private func ensureTask(_ task: TaskID) {
        if !tasks.contains(where: { $0.task == task }) {
            tasks.append(TaskProgress(task: task))
        }
    }

    private func update(_ task: TaskID, _ change: (inout TaskProgress) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.task == task }) else { return }
        change(&tasks[index])
    }

    private func setStage(_ stage: String, for task: TaskID) {
        update(task) { $0.stage = stage }
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > RunCoordinator.logCapacity {
            log.removeFirst(log.count - RunCoordinator.logCapacity)
        }
    }

    private func refreshBrowser() {
        guard let browser = model?.runBrowser else { return }
        Task { await browser.refresh() }
    }

    private func browserTitle(for directory: URL) -> String? {
        model?.runBrowser.runs.first { $0.directory.standardizedFileURL == directory.standardizedFileURL }?.title
    }
}
