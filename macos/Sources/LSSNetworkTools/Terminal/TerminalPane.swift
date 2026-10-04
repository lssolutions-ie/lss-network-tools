import SwiftUI
@preconcurrency import SwiftTerm

/// Hosts the session's SwiftTerm view inside SwiftUI.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    /// The terminal takes whatever space it is offered. Without this SwiftUI
    /// consults the view's own size, and the shared view — already laid out
    /// at full height on the Run Audit screen — then forces a taller minimum
    /// on a task screen, pushing the header out of the window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LocalProcessTerminalView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }
}

/// The embedded terminal with an optional status strip when the process has
/// ended. After the *interactive* CLI exits the strip offers Relaunch (Return);
/// after a non-interactive run the pane still shows the run's log, so the
/// strip only says the run has finished — its outcome is in the run's phase
/// banner and in Previous Runs, and Return must not start the interactive
/// CLI by surprise. The run progress view hides the strip altogether.
struct TerminalPane: View {
    @Environment(AppModel.self) private var model
    var showsExitStrip = true

    var body: some View {
        ZStack(alignment: .bottom) {
            TerminalHostView(session: model.terminal)
                .background(Color.black)
            if showsExitStrip, case .exited(let code) = model.terminal.state {
                if model.terminal.lastLaunchKind == .interactive {
                    interactiveExitStrip(code)
                } else {
                    runFinishedStrip
                }
            }
        }
        .onAppear { model.launchTerminalIfNeeded() }
    }

    private func interactiveExitStrip(_ code: Int32?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "stop.circle")
            Text(exitDescription(code))
            Spacer()
            Button("Relaunch") { model.launchTerminal() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.runCoordinator.isActive)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var runFinishedStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
            Text("Run finished. The terminal shows its log; the outcome is in Previous Runs.")
            Spacer()
            Button("Open Interactive CLI Session") { model.launchTerminal() }
                .disabled(model.runCoordinator.isActive)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func exitDescription(_ code: Int32?) -> String {
        switch code {
        case .some(0): "The CLI session ended."
        case .some(let value): "The CLI session ended with exit code \(value)."
        case .none: "The CLI session ended."
        }
    }
}
