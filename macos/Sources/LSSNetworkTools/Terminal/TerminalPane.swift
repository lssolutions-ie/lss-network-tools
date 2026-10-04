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
/// ended. The strip relaunches the *interactive* CLI, so the run progress view
/// hides it (its phase banner reports the outcome instead).
struct TerminalPane: View {
    @Environment(AppModel.self) private var model
    var showsExitStrip = true

    var body: some View {
        ZStack(alignment: .bottom) {
            TerminalHostView(session: model.terminal)
                .background(Color.black)
            if showsExitStrip, case .exited(let code) = model.terminal.state {
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
        }
        .onAppear { model.launchTerminalIfNeeded() }
    }

    private func exitDescription(_ code: Int32?) -> String {
        switch code {
        case .some(0): "The CLI session ended."
        case .some(let value): "The CLI session ended with exit code \(value)."
        case .none: "The CLI session ended."
        }
    }
}
