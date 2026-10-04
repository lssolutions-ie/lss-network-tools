import SwiftUI
import LSSCore

/// Live view of the current run: header, phase banner, per-task list and the
/// terminal pane (the log, and where the sudo password is typed).
struct RunProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let coordinator = model.runCoordinator
        VStack(spacing: 0) {
            // The status block takes exactly its content height; `fixedSize`
            // stops the VStack from stretching it, so the terminal below is
            // the single flexible region and absorbs the remaining height
            // instead of collapsing to its minimum.
            VStack(spacing: 0) {
                header(coordinator)
                    .padding(16)
                Divider()
                PhaseBanner(coordinator: coordinator)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                if !coordinator.tasks.isEmpty {
                    Divider()
                    TaskProgressList(tasks: coordinator.tasks)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            TerminalPane(showsExitStrip: false)
                .frame(minHeight: 160, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

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
                } else if coordinator.isActive, !coordinator.isBuildingReport {
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
                    if let directory = coordinator.runDirectory, FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
                        Button {
                            model.showInPreviousRuns(directory: directory)
                        } label: {
                            Label("Show in Previous Runs", systemImage: "clock.arrow.circlepath")
                        }
                    }
                    Button("Done") { coordinator.dismiss() }
                        .help("Return to the idle terminal")
                }
                if let directory = coordinator.runDirectory, FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
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
            return coordinator.isBuildingReport ? "Starting the report builder…" : "Starting the command-line tool…"
        case .awaitingPassword:
            return "Type your administrator password in the terminal below"
        case .awaitingAuthentication:
            return "Authenticate as an administrator in the macOS dialog"
        case .running:
            if coordinator.isBuildingReport { return "Rebuilding the report…" }
            if let running = coordinator.runningTask, let index = coordinator.tasks.firstIndex(of: running) {
                return "Running task \(index + 1) of \(coordinator.tasks.count) — \(running.task.title)"
            }
            return coordinator.completedTaskCount == coordinator.tasks.count && !coordinator.tasks.isEmpty
                ? "Building the report…"
                : "Running…"
        case .finished(let code):
            if let code { return code.summary }
            if let raw = coordinator.exitCode { return "The run ended with exit code \(raw)." }
            return "The run ended."
        case .failedToLaunch:
            return "The run could not start"
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
            return "sudo runs the tool as root. If it asks for a password, type it in the terminal pane; nothing starts until it is accepted."
        case .awaitingPassword:
            return "sudo needs it to run the network scans as root. The password goes straight to sudo and is not stored by the app."
        case .awaitingAuthentication:
            return "The privileged helper runs the tools installed under your user account (Homebrew) as root only after administrator authentication. The dialog belongs to LSS Network Tools; the password goes to macOS, not to this app."
        case .running:
            if let stage = coordinator.runningTask?.stage { return stage }
            if coordinator.isBuildingReport { return "Building the TXT report, findings and manifest\(skipsPDF ? "" : ", then the PDF")." }
            return "\(coordinator.completedTaskCount) of \(coordinator.tasks.count) tasks completed"
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
            let seconds = Int(finished.timeIntervalSince(started).rounded())
            parts.append(seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s")
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
