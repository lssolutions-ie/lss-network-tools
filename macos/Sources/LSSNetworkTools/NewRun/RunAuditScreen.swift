import SwiftUI
import LSSCore

/// Main pane for Run Audit and every task screen: task header, the New Run /
/// Continue Previous Run buttons, then either the live run progress or the
/// terminal pane behind an idle placeholder. The interactive CLI starts only
/// on request (button or Terminal menu).
struct RunAuditScreen: View {
    @Environment(AppModel.self) private var model
    let task: TaskID?

    var body: some View {
        let coordinator = model.runCoordinator
        VStack(spacing: 0) {
            if let task {
                TaskHeader(task: task)
                Divider()
            }
            if model.cli == nil {
                CLIMissingBanner()
                Divider()
            }
            actionBar
            Divider()
            if coordinator.phase != .idle {
                RunProgressView()
            } else {
                idleTerminal
            }
        }
        // Report no minimum height. The AppKit split view behind
        // NavigationSplitView re-fits to "window height + detail minimum"
        // whenever the detail content changes (a sidebar click), and a
        // non-zero minimum here pushed the whole content — header and
        // sidebar top included — out of the window.
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    private var actionBar: some View {
        let coordinator = model.runCoordinator
        let runsDisabled = model.cli == nil || coordinator.isActive
        return HStack(spacing: 10) {
            Button {
                model.presentNewRun(task: task)
            } label: {
                Label(task.map { "Run Task \($0.rawValue)…" } ?? "New Run…", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(runsDisabled)
            .help(task == nil ? "Start a full audit or a selection of tasks in a new run directory" : "Run this task in a new run directory")

            Menu {
                if model.runBrowser.runs.isEmpty {
                    Text("No previous runs")
                } else {
                    ForEach(model.runBrowser.runs.prefix(15)) { run in
                        Button(menuTitle(for: run)) {
                            model.presentContinueRun(run, task: task)
                        }
                    }
                    if model.runBrowser.runs.count > 15 {
                        Divider()
                        Button("Open Previous Runs…") { model.selection = .previousRuns }
                    }
                }
            } label: {
                Label("Continue Previous Run…", systemImage: "arrow.uturn.forward")
            }
            .fixedSize()
            .disabled(runsDisabled)
            .help("Add tasks to an existing run directory (--run-dir)")

            Spacer()

            if model.cli == nil {
                Text("Install the command-line tool to start runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if coordinator.isActive {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(coordinator.isBuildingReport ? "Rebuilding report…" : "Run in progress")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if model.terminal.state == .running {
                Label("Interactive CLI session running", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func menuTitle(for run: RunSummary) -> String {
        var title = run.title
        if let date = run.generatedAt {
            title += " · " + date.formatted(date: .abbreviated, time: .omitted)
        } else if let text = run.generatedAtText {
            title += " · " + text
        }
        return title
    }

    /// The pane keeps a small *ideal* height: the AppKit split view behind
    /// NavigationSplitView re-fits to the detail column's ideal size whenever
    /// its content changes, and a greedy ideal here would grow the whole
    /// window content past the window (pushing the header off screen).
    private var idleTerminal: some View {
        ZStack {
            TerminalPane()
            if model.terminal.state == .idle {
                Rectangle()
                    .fill(.background)
                ContentUnavailableView {
                    Label("No session running", systemImage: "terminal")
                } description: {
                    Text("Start a run, or open the interactive CLI. Runs show their progress here and type into the same terminal.")
                } actions: {
                    HStack(spacing: 10) {
                        Button {
                            model.presentNewRun(task: task)
                        } label: {
                            Label(task.map { "Run Task \($0.rawValue)…" } ?? "New Run…", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.cli == nil)
                        Button("Open Interactive CLI Session") { model.launchTerminal() }
                    }
                }
            }
        }
        .frame(minHeight: 160, idealHeight: 320, maxHeight: .infinity)
    }
}
