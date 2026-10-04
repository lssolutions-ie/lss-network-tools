import SwiftUI
import LSSCore

/// Live view of the current run and, once it has finished, its results in the
/// same place: header, phase banner, the overall progress bar while the run is
/// active, the per-task list, then `RunResultsView` for the run directory the
/// engine wrote. The terminal is the run's **log**: hidden behind "Show log"
/// (`AppModel.showRunLog`) and opened on its own while sudo waits for the
/// password — the one moment the user must type into it.
///
/// The terminal stays mounted while hidden. SwiftTerm resizes the pty from the
/// view's bounds, so removing the view or giving it a 0-pt height would collapse
/// the child's terminal to 0 rows mid-run; instead it fills the whole content
/// area behind the progress/results at opacity 0 (hit-testing off) and shrinks
/// to the log region when shown. It is one view at one place in the hierarchy
/// whatever the toggle says — the shared `NSView` must never be in two places.
struct RunProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let coordinator = model.runCoordinator
        let logVisible = model.isRunLogVisible
        let awaitingPassword = coordinator.phase == .awaitingPassword
        VStack(spacing: 0) {
            // The status block takes exactly its content height; `fixedSize`
            // stops the VStack from stretching it, so the region below is the
            // single flexible one.
            VStack(spacing: 0) {
                header(coordinator)
                    .padding(16)
                Divider()
                PhaseBanner(coordinator: coordinator)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                if coordinator.isActive {
                    RunProgressBar(coordinator: coordinator)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            GeometryReader { geometry in
                let logHeight = max(160, min((geometry.size.height * 0.4).rounded(), 360))
                ZStack(alignment: .bottom) {
                    TerminalPane(showsExitStrip: false)
                        .frame(height: logVisible ? logHeight : nil)
                        .opacity(logVisible ? 1 : 0)
                        .allowsHitTesting(logVisible)
                        .accessibilityHidden(!logVisible)
                    VStack(spacing: 0) {
                        content(coordinator)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if logVisible {
                            Divider()
                            if awaitingPassword {
                                passwordCaption
                                Divider()
                            }
                            // Reserves the log's region; the terminal is drawn there.
                            Color.clear.frame(height: logHeight)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            logBar(coordinator, logVisible: logVisible, awaitingPassword: awaitingPassword)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: awaitingPassword) { _, waiting in
            // The log has just opened for the prompt: put the cursor in it.
            if waiting { focusTerminal() }
        }
        .onAppear {
            // A deletion that fell back from the helper to sudo arrives here with
            // the phase already `.awaitingPassword`; `onChange` never fires then.
            if awaitingPassword { focusTerminal() }
        }
        .onChange(of: logVisible) { _, visible in
            // The hidden pane must not keep the keyboard: every key would go to
            // the pty invisibly.
            if !visible { releaseTerminalFocus() }
        }
    }

    // MARK: Keyboard focus

    private func focusTerminal() {
        let terminalView = model.terminal.terminalView
        terminalView.window?.makeFirstResponder(terminalView)
    }

    private func releaseTerminalFocus() {
        let terminalView = model.terminal.terminalView
        guard let window = terminalView.window else { return }
        let responder = window.firstResponder
        let terminalHasFocus = responder === terminalView
            || ((responder as? NSView)?.isDescendant(of: terminalView) ?? false)
        if terminalHasFocus { window.makeFirstResponder(nil) }
    }

    // MARK: Content

    /// What fills the region between the status block and the log: the results
    /// once the run has finished and wrote a directory, the task list while it is
    /// active, otherwise a short note.
    @ViewBuilder
    private func content(_ coordinator: RunCoordinator) -> some View {
        if case .finished = coordinator.phase, let directory = coordinator.runDirectory, Self.directoryExists(directory) {
            RunResultsView(
                directory: directory,
                focusTask: coordinator.tasks.count == 1 ? coordinator.tasks[0].task : nil,
                mode: resultsMode(coordinator),
                reloadToken: coordinator.browserRefreshCount
            )
        } else if coordinator.isActive {
            if coordinator.tasks.isEmpty {
                Color.clear
            } else {
                ScrollView {
                    TaskProgressList(tasks: coordinator.tasks)
                        .padding(16)
                }
            }
        } else if coordinator.isDeletingRun {
            ContentUnavailableView {
                Label("The run was not deleted", systemImage: "trash.slash")
            } description: {
                Text(deletionFailureText(coordinator))
            }
        } else {
            VStack(spacing: 0) {
                if !coordinator.tasks.isEmpty {
                    TaskProgressList(tasks: coordinator.tasks)
                        .padding(16)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }
                ContentUnavailableView {
                    Label("No results were written", systemImage: "tray")
                } description: {
                    Text(noResultsText(coordinator))
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// Why there is nothing to show, by cause: a report rebuild that failed, a
    /// run that never started (sudo rejected, helper refused — the directory of a
    /// continued run is known but untouched), a run directory that is gone, or a
    /// run that ended before creating one.
    private func noResultsText(_ coordinator: RunCoordinator) -> String {
        if coordinator.isBuildingReport { return "The report could not be rebuilt; the log has the details." }
        if case .failedToLaunch = coordinator.phase { return "The run did not start; the log has the details." }
        if coordinator.runDirectory != nil { return "The run directory is no longer on disk; the log has the details." }
        return "The run ended before it wrote a run directory; the log has the details."
    }

    private func deletionFailureText(_ coordinator: RunCoordinator) -> String {
        if let directory = coordinator.deletingDirectory, let failure = coordinator.deletionFailure(for: directory) {
            return failure
        }
        return "The command-line tool ended before it removed the run directory."
    }

    private func resultsMode(_ coordinator: RunCoordinator) -> RunResultsView.Mode {
        if coordinator.isBuildingReport { return .report }
        return coordinator.tasks.count == 1 ? .task : .overview
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Log

    private var passwordCaption: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").foregroundStyle(.orange)
            Text("sudo is asking for your password — type it here")
                .font(.callout.weight(.medium))
            Spacer()
            Text("The password goes straight to sudo; the app never sees or stores it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    /// The thin bar with the Show log / Hide log toggle.
    private func logBar(_ coordinator: RunCoordinator, logVisible: Bool, awaitingPassword: Bool) -> some View {
        let forced = awaitingPassword || model.forceRunLogForAutomation
        return HStack(spacing: 12) {
            Button {
                model.showRunLog.toggle()
            } label: {
                Label(logVisible ? "Hide log" : "Show log", systemImage: logVisible ? "chevron.down" : "chevron.up")
            }
            .controlSize(.small)
            .disabled(forced)
            .help(awaitingPassword
                  ? "The log stays open while sudo waits for the password"
                  : "The terminal pane with the command-line tool's output (progress-protocol lines are not shown)")
            if awaitingPassword {
                Label("The log stays open while sudo waits for the password.", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(coordinator.isActive
                     ? "The terminal is the run's log; the password prompt opens it on its own."
                     : "The terminal shows the run's log.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: Header

    private func header(_ coordinator: RunCoordinator) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(coordinator.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                if !coordinator.subtitle.isEmpty {
                    Text(coordinator.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let directory = coordinator.runDirectory {
                    Text(directory.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if coordinator.isActive, !coordinator.isBuildingReport, !coordinator.isDeletingRun {
                    Text("Run directory: assigned by the tool when the run starts")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if coordinator.isActive {
                    Button(role: .destructive) {
                        coordinator.cancel()
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .help("Stops the command-line tool (SIGTERM); the run can be continued later from Previous Runs")
                } else {
                    if let directory = coordinator.runDirectory, Self.directoryExists(directory) {
                        Button {
                            model.showInPreviousRuns(directory: directory)
                        } label: {
                            Label("Show in Previous Runs", systemImage: "clock.arrow.circlepath")
                        }
                    }
                    Button("Done") { coordinator.dismiss() }
                        .help("Clear the finished run from this screen")
                }
                if let directory = coordinator.runDirectory, Self.directoryExists(directory) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([directory])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }
            }
        }
    }
}

/// Overall progress of the active run: a determinate bar over the run's tasks
/// (done + failed + skipped of all), indeterminate while launching, waiting
/// for the password or the authentication dialog, or building the report;
/// "n of m" and the elapsed time on the right; the current stage below.
struct RunProgressBar: View {
    let coordinator: RunCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                if let (completed, total) = determinate {
                    ProgressView(value: Double(completed), total: Double(total))
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                HStack(spacing: 6) {
                    if !coordinator.tasks.isEmpty {
                        Text("\(coordinator.completedTaskCount) of \(coordinator.tasks.count)")
                        if coordinator.startedAt != nil {
                            Text("·").foregroundStyle(.tertiary)
                        }
                    }
                    if let started = coordinator.startedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(Self.elapsedText(from: started, to: context.date))
                        }
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            if let stage = coordinator.runningTask?.stage {
                Text(stage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// (completed, total) while tasks are running; nil for an indeterminate bar.
    private var determinate: (Int, Int)? {
        guard coordinator.phase == .running, !coordinator.isBuildingReport, !coordinator.isDeletingRun,
              !coordinator.tasks.isEmpty else { return nil }
        let completed = coordinator.completedTaskCount
        // Every task done and the run still active: the engine is building the report.
        guard completed < coordinator.tasks.count else { return nil }
        return (completed, coordinator.tasks.count)
    }

    /// `12 s` / `3 min 05 s`.
    static func elapsedText(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start).rounded(.down)))
        return seconds >= 60 ? String(format: "%d min %02d s", seconds / 60, seconds % 60) : "\(seconds) s"
    }
}

/// One-line status for the current phase, coloured by outcome.
struct PhaseBanner: View {
    let coordinator: RunCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                icon
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(primary)
                        .font(.headline)
                    if let secondary {
                        Text(secondary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            if let error = coordinator.lastError {
                Label {
                    Text(errorText(error))
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let pdfFailure = coordinator.pdfFailure {
                Label("PDF report: \(pdfFailure)", systemImage: "doc.badge.ellipsis")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = coordinator.warnings.last {
                Label {
                    Text(warningText(warning, count: coordinator.warnings.count))
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var icon: some View {
        switch coordinator.phase {
        case .idle:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .launching, .running:
            ProgressView().controlSize(.small)
        case .awaitingPassword:
            Image(systemName: "key.fill").font(.title3).foregroundStyle(.orange)
        case .awaitingAuthentication:
            Image(systemName: "person.badge.key.fill").font(.title3).foregroundStyle(.orange)
        case .finished(let code):
            Image(systemName: finishedSymbol(code)).font(.title3).foregroundStyle(tint)
        case .failedToLaunch:
            Image(systemName: "xmark.octagon.fill").font(.title3).foregroundStyle(.red)
        }
    }

    private var primary: String {
        switch coordinator.phase {
        case .idle:
            return "No run in progress"
        case .launching:
            if coordinator.isBuildingReport { return "Starting the report builder…" }
            return "Starting the command-line tool…"
        case .awaitingPassword:
            return "Type your administrator password in the log below"
        case .awaitingAuthentication:
            return "Authenticate as an administrator in the macOS dialog"
        case .running:
            if coordinator.isBuildingReport { return "Rebuilding the report…" }
            if coordinator.isDeletingRun { return "Deleting run…" }
            if let running = coordinator.runningTask, let index = coordinator.tasks.firstIndex(of: running) {
                return "Running task \(index + 1) of \(coordinator.tasks.count) — \(running.task.title)"
            }
            return coordinator.completedTaskCount == coordinator.tasks.count && !coordinator.tasks.isEmpty
                ? "Building the report…"
                : "Running…"
        case .finished(let code):
            // An `error` event before `bye 0` is a failure too (`finish` keeps the screen up then).
            if coordinator.isDeletingRun, code != .success || coordinator.lastError != nil { return "The run was not deleted." }
            if let code { return code.summary }
            if let raw = coordinator.exitCode { return "The run ended with exit code \(raw)." }
            return "The run ended."
        case .failedToLaunch:
            return coordinator.isDeletingRun ? "The run could not be deleted" : "The run could not start"
        }
    }

    private var secondary: String? {
        switch coordinator.phase {
        case .idle:
            return nil
        case .launching:
            if coordinator.usesHelper {
                return "The privileged helper is starting the tool as root."
            }
            return "sudo runs the tool as root. If it asks for a password, the log opens below; type it there — nothing starts until it is accepted."
        case .awaitingPassword:
            return "sudo needs it to run the command-line tool as root. The password goes straight to sudo and is not stored by the app."
        case .awaitingAuthentication:
            return "The privileged helper runs the tools installed under your user account (Homebrew) as root only after administrator authentication. The dialog belongs to LSS Network Tools; the password goes to macOS, not to this app."
        case .running:
            // The task counter and the current stage live under the progress bar
            // (`RunProgressBar`); repeating them here said the same thing twice.
            if coordinator.isBuildingReport { return "Building the TXT report, findings and manifest\(skipsPDF ? "" : ", then the PDF")." }
            if coordinator.isDeletingRun { return "The command-line tool is removing the run directory." }
            return nil
        case .finished:
            return finishedSummary
        case .failedToLaunch(let message):
            return message
        }
    }

    /// Skip PDF of the current run *or* report build — `coordinator.request`
    /// is nil while a report is rebuilt, so the `BuildReportRequest` is read
    /// from the mode.
    private var skipsPDF: Bool {
        if let request = coordinator.request { return request.skipPDF }
        if case .report(let request)? = coordinator.mode { return request.skipPDF }
        return false
    }

    private var finishedSummary: String? {
        var parts: [String] = []
        if !coordinator.tasks.isEmpty {
            var ok = 0, warn = 0, failed = 0, skipped = 0
            for task in coordinator.tasks {
                switch task.state {
                case .done(let status): if status == "completed_with_warnings" { warn += 1 } else { ok += 1 }
                case .failed: failed += 1
                case .skipped: skipped += 1
                case .pending, .running: break
                }
            }
            var counts: [String] = []
            if ok > 0 { counts.append("\(ok) succeeded") }
            if warn > 0 { counts.append("\(warn) with warnings") }
            if failed > 0 { counts.append("\(failed) failed") }
            if skipped > 0 { counts.append("\(skipped) skipped") }
            let pending = coordinator.tasks.count - ok - warn - failed - skipped
            if pending > 0 { counts.append("\(pending) not run") }
            if !counts.isEmpty { parts.append(counts.joined(separator: " · ")) }
        }
        if let pdf = coordinator.reportPDF {
            parts.append("PDF: \(pdf)")
        } else if let txt = coordinator.reportTXT {
            parts.append("Report: \(txt)")
        }
        if let started = coordinator.startedAt, let finished = coordinator.finishedAt {
            parts.append(RunProgressBar.elapsedText(from: started, to: finished))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private var tint: Color {
        switch coordinator.phase {
        case .idle: .gray
        case .launching, .running: .blue
        case .awaitingPassword, .awaitingAuthentication: .orange
        case .finished(let code):
            switch code {
            case .success?: .green
            case .taskFailed?: .orange
            case .interrupted?, nil: .gray
            case .usage?, .missingDependencies?, .consentRequired?, .notRoot?: .red
            }
        case .failedToLaunch: .red
        }
    }

    private func finishedSymbol(_ code: CLIExitCode?) -> String {
        switch code {
        case .success?: "checkmark.circle.fill"
        case .taskFailed?: "exclamationmark.triangle.fill"
        case .interrupted?: "stop.circle.fill"
        case nil: "questionmark.circle.fill"
        case .usage?, .missingDependencies?, .consentRequired?, .notRoot?: "xmark.octagon.fill"
        }
    }

    private func errorText(_ error: (code: String?, message: String?)) -> String {
        switch (error.code, error.message) {
        case (let code?, let message?): "\(code): \(message)"
        case (let code?, nil): code
        case (nil, let message?): message
        case (nil, nil): "The command-line tool reported an error."
        }
    }

    private func warningText(_ warning: (code: String?, message: String?), count: Int) -> String {
        let text = warning.message ?? warning.code ?? "warning"
        return count > 1 ? "\(text) (\(count) warnings)" : text
    }
}

/// Two-column list of the run's tasks with state and current stage.
struct TaskProgressList: View {
    let tasks: [TaskProgress]

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 600), spacing: 10, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(tasks) { progress in
                TaskProgressRow(progress: progress)
            }
        }
    }
}

struct TaskProgressRow: View {
    let progress: TaskProgress

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: progress.task.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text("\(progress.task.rawValue). \(progress.task.title)")
                .lineLimit(1)
            Spacer(minLength: 8)
            stateView
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .help(helpText)
    }

    @ViewBuilder
    private var stateView: some View {
        switch progress.state {
        case .pending:
            Label("Pending", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(progress.stage ?? "Running…")
            }
            .foregroundStyle(.blue)
        case .done(let status):
            if status == "completed_with_warnings" {
                Label("Warnings", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed(let status):
            Label(statusLabel(status), systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .skipped:
            Label("Skipped", systemImage: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "no_output": "No result written"
        case "cancelled": "Cancelled"
        case "interrupted": "Interrupted"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var helpText: String {
        var parts = [progress.task.summary]
        if !progress.jsonFiles.isEmpty { parts.append("Wrote: " + progress.jsonFiles.joined(separator: ", ")) }
        return parts.joined(separator: "\n")
    }
}
