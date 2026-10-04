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
///   No password, so `.awaitingPassword` never happens.
/// * **terminal** — `sudo <wrapper> …` in the shared `TerminalSession` (M3,
///   unchanged): the pane is the log and where the sudo password is typed.
///
/// A run that wanted the helper but found it unavailable falls back to the
/// terminal route with a warning.
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
        case .launching, .awaitingPassword, .running: true
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
    /// `sudo <wrapper> --run-task …` in the shared terminal. The SSH password
    /// travels only in the child's environment (`LSS_SSH_PASSWORD`: preserved
    /// through sudo, or set by the helper).
    func start(_ request: RunTaskRequest, sshPassword: String?) {
        reset(mode: .run(request))
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
        let command = ArgumentBuilder.sudoCommand(
            wrapper: launch.executable,
            arguments: launch.arguments + arguments,
            preserveEnvironment: sshPassword == nil ? [] : ["LSS_SSH_PASSWORD"]
        )
        var environment = ProcessRunner.baseEnvironment
        environment["TERM_PROGRAM"] = "LSSNetworkTools"
        if let sshPassword { environment["LSS_SSH_PASSWORD"] = sshPassword }

        if case .existingRun(let directory) = request.context { runDirectory = directory }
        tasks = request.selection.taskIDs.map { TaskProgress(task: $0) }
        launchPreferringHelper(arguments: arguments, sshPassword: sshPassword) { [weak self] in
            self?.launchProcess(executable: command.executable, arguments: command.arguments, environment: environment)
        }
    }

    /// `sudo <wrapper> --build-report <run-dir> …`.
    func buildReport(_ request: BuildReportRequest) {
        reset(mode: .report(request))
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
        let command = ArgumentBuilder.sudoCommand(wrapper: launch.executable, arguments: launch.arguments + arguments, preserveEnvironment: [])
        var environment = ProcessRunner.baseEnvironment
        environment["TERM_PROGRAM"] = "LSSNetworkTools"
        runDirectory = request.runDirectory
        launchPreferringHelper(arguments: arguments, sshPassword: nil) { [weak self] in
            self?.launchProcess(executable: command.executable, arguments: command.arguments, environment: environment)
        }
    }

    /// Terminates the process (sudo relays SIGTERM; the script's INT/TERM trap
    /// exits 130 and its EXIT trap kills background tools). On the helper route
    /// the helper sends SIGTERM (SIGKILL after 5 s) and the run ends with its reply.
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
                Task { _ = await client.cancel(token: token) }
            }
        case .terminal, .none:
            model?.terminal.terminate()
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
    /// route otherwise, or when the helper does not answer `version()`.
    private func launchPreferringHelper(arguments: [String], sshPassword: String?, viaTerminal: @escaping @MainActor () -> Void) {
        guard let model, model.privilegeMode == .helper else {
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
                await self.runViaHelper(arguments: arguments, sshPassword: sshPassword, generation: generation)
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
        let needsSettle = terminal.state == .running
        if needsSettle { terminal.terminate() }
        attach(to: terminal)
        phase = .launching
        startedAt = .now
        Task { [weak self] in
            // Let sudo tear down the previous pty session before the view is reused.
            if needsSettle { try? await Task.sleep(for: .milliseconds(250)) }
            guard let self, self.phase == .launching else { return }
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
                switch status {
                case "skipped": progress.state = .skipped
                case "failed", "no_output": progress.state = .failed(status: status ?? "failed")
                default: progress.state = .done(status: status ?? "success")
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

    private func runViaHelper(arguments: [String], sshPassword: String?, generation: Int) async {
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
        terminal.display(ArraySlice(Array("\u{1b}[2J\u{1b}[H\u{1b}[2m— running through the privileged helper; no password needed —\u{1b}[0m\r\n".utf8)))

        let request = HelperRunRequest(arguments: arguments, sshPassword: sshPassword, callerUID: getuid())
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
        guard self.generation == generation else { return }
        helperToken = nil
        switch outcome {
        case .success(.exited(let code)):
            handleProcessExit(code: code)
        case .success(.refused(let reason)):
            failHelperRun("The privileged helper refused this run: \(reason) Choose “sudo in the terminal pane” in Settings → Privileges to run it with sudo instead.")
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
