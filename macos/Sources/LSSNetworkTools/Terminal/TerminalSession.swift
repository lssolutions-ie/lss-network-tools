import AppKit
import Observation
@preconcurrency import SwiftTerm

/// Owns the SwiftTerm view and the pty-backed child process so the terminal
/// survives SwiftUI view updates and sidebar navigation.
///
/// One session serves both the interactive CLI and non-interactive runs: the
/// `RunCoordinator` taps every byte the child writes (`outputTap`) to pick the
/// `@@LSS` progress events out of the stream while the view keeps rendering it.
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

    /// Called on the main actor with every chunk the child process writes,
    /// after the chunk has been fed to the terminal view.
    @ObservationIgnored var outputTap: (@MainActor (ArraySlice<UInt8>) -> Void)?

    /// Called on the main actor when the child process ends (exit code when
    /// known, nil for an I/O error or an explicit `terminate()`).
    @ObservationIgnored var onProcessExit: (@MainActor (Int32?) -> Void)?

    let terminalView: TappedTerminalView
    private let coordinator = TerminalCoordinator()
    private var lastLaunch: (executable: String, arguments: [String], environment: [String: String])?

    init() {
        terminalView = TappedTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        terminalView.processDelegate = coordinator
        coordinator.session = self
        terminalView.tap = { [weak self] slice in
            self?.outputTap?(slice)
        }
        // A fixed dark profile: an idle or sparsely filled terminal would
        // otherwise draw the system (light) background and vanish against the
        // pane. Dark reads as a terminal/log in both appearances and matches
        // what the running CLI draws when it clears the screen.
        terminalView.nativeBackgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.90, alpha: 1)
    }

    /// Starts `executable arguments...` on the pty with a fully specified
    /// environment. A process that is still running is terminated first.
    func launch(executable: String, arguments: [String], environment: [String: String]) {
        lastLaunch = (executable, arguments, environment)
        if state == .running {
            terminalView.terminate()
        }
        if state != .idle {
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

    /// Sends SIGTERM to the child. SwiftTerm cancels its exit monitor on an
    /// explicit terminate, so the delegate never reports the exit: the state is
    /// updated here and `onProcessExit` is invoked with a nil code.
    func terminate() {
        guard state == .running else { return }
        terminalView.terminate()
        state = .exited(nil)
        onProcessExit?(nil)
    }

    /// Writes `text` to the child's stdin, as if typed in the pane.
    func send(text: String) {
        guard state == .running else { return }
        terminalView.send(txt: text)
    }

    /// Renders bytes in the pane without a process (fixture replay in
    /// `RunCoordinator.simulate`); `outputTap` is not invoked.
    func display(_ bytes: ArraySlice<UInt8>) {
        terminalView.feed(byteArray: bytes)
    }

    fileprivate func processDidExit(code: Int32?) {
        guard state == .running else { return }
        state = .exited(code)
        onProcessExit?(code)
    }

    fileprivate func titleDidChange(_ newTitle: String) {
        title = newTitle
    }
}

/// `LocalProcessTerminalView` whose `dataReceived(slice:)` is `open`: the
/// override feeds the terminal as before and then hands the same bytes to
/// `tap`. SwiftTerm delivers these chunks on the main queue (its
/// `LocalProcess` is created with the default dispatch queue), and the view is
/// main-actor isolated like every `NSView`, so no hop is needed here.
final class TappedTerminalView: LocalProcessTerminalView {
    var tap: (@MainActor (ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        tap?(slice)
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
