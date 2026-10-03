import SwiftUI
@preconcurrency import SwiftTerm

/// Hosts the session's SwiftTerm view inside SwiftUI.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

/// The embedded CLI session with a status strip when the process has ended.
struct TerminalPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .bottom) {
            TerminalHostView(session: model.terminal)
                .background(Color.black)
            if case .exited(let code) = model.terminal.state {
                HStack(spacing: 12) {
                    Image(systemName: "stop.circle")
                    Text(exitDescription(code))
                    Spacer()
                    Button("Relaunch") { model.launchTerminal() }
                        .keyboardShortcut(.defaultAction)
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
        case .none: "The CLI session ended unexpectedly."
        }
    }
}
