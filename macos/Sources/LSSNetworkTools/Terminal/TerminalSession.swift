import AppKit
import Observation
@preconcurrency import SwiftTerm

/// Owns the SwiftTerm view and the pty-backed child process so the terminal
/// survives SwiftUI view updates and sidebar navigation.
@MainActor
@Observable
final class TerminalSession {
    enum State: Equatable {
        case idle
        case running
        case exited(Int32?)
    }

    private(set) var state: State = .idle
    private(set) var title: String = ""

    let terminalView: LocalProcessTerminalView
    private let coordinator = TerminalCoordinator()
    private var lastLaunch: (executable: String, arguments: [String], environment: [String: String])?

    init() {
        terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        terminalView.processDelegate = coordinator
        coordinator.session = self
        // Colours follow the system appearance (SwiftTerm re-applies
        // textColor/textBackgroundColor on appearance changes), like Terminal.app's
        // default profile.
    }

    /// Starts `executable arguments...` on the pty with a fully specified environment.
    func launch(executable: String, arguments: [String], environment: [String: String]) {
        lastLaunch = (executable, arguments, environment)
        if case .exited = state {
            // Clear the previous session's screen before relaunching.
            terminalView.feed(text: "\r\n\u{1b}[2J\u{1b}[H")
        }
        let env = environment.map { "\($0.key)=\($0.value)" }
        terminalView.startProcess(executable: executable, args: arguments, environment: env, execName: nil)
        state = .running
    }

    func relaunch() {
        guard let last = lastLaunch else { return }
        launch(executable: last.executable, arguments: last.arguments, environment: last.environment)
    }

    func terminate() {
        guard state == .running else { return }
        terminalView.terminate()
    }

    fileprivate func processDidExit(code: Int32?) {
        state = .exited(code)
    }

    fileprivate func titleDidChange(_ newTitle: String) {
        title = newTitle
    }
}

/// SwiftTerm delegate. Callbacks may arrive off the main actor, so every state
/// change hops back to it.
private final class TerminalCoordinator: NSObject, LocalProcessTerminalViewDelegate {
    weak var session: TerminalSession?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let session = session
        Task { @MainActor in session?.titleDidChange(title) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let session = session
        Task { @MainActor in session?.processDidExit(code: exitCode) }
    }
}
