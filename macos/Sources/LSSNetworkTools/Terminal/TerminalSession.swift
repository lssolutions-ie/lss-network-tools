import AppKit
import Observation
import LSSCore
@preconcurrency import SwiftTerm

/// Owns the SwiftTerm view and the pty-backed child process so the terminal
/// survives SwiftUI view updates and sidebar navigation.
///
/// One session serves both the interactive CLI and non-interactive runs: the
/// `RunCoordinator` taps every byte the child writes (`outputTap`) to pick the
/// `@@LSS` progress events out of the stream, while the view renders the same
/// stream minus those event lines (`TappedTerminalView`): the pane is the run's
/// log, not its protocol.
@MainActor
@Observable
final class TerminalSession {
    enum State: Equatable {
        case idle
        case running
        case exited(Int32?)
    }

    /// What the pane is — or, after an exit, was last — running.
    enum LaunchKind: Equatable {
        /// `sudo <wrapper>` (or a login shell): started by the user, relaunchable.
        case interactive
        /// A non-interactive run or report build started by `RunCoordinator`.
        case run
    }

    private(set) var state: State = .idle
    private(set) var title: String = ""
    /// nil before the first launch.
    private(set) var lastLaunchKind: LaunchKind?

    /// Called on the main actor with every chunk the child process writes,
    /// after the chunk has been fed to the terminal view.
    @ObservationIgnored var outputTap: (@MainActor (ArraySlice<UInt8>) -> Void)?

    /// Called on the main actor when the child process ends (exit code when
    /// known, nil for an I/O error or an explicit `terminate()`).
    @ObservationIgnored var onProcessExit: (@MainActor (Int32?) -> Void)?

    let terminalView: TappedTerminalView
    private let coordinator = TerminalCoordinator()
    /// The interactive session's command, for `relaunch()`. Only the
    /// interactive launch is remembered: a run's environment carries
    /// `LSS_SSH_PASSWORD` (Task 19) and `LSS_PROGRESS_TOKEN`, which must not
    /// outlive the process that needed them — `launch()` keeps no copy.
    @ObservationIgnored private var interactiveLaunch: (executable: String, arguments: [String], environment: [String: String])?

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
        // OSC 52 lets the program on the pty write the system clipboard (and,
        // with a `?` payload, read it back into the stream). The engine's
        // output repeats bytes from untrusted devices — hostnames, service
        // banners, SNMP strings — so a no-op handler is registered: SwiftTerm
        // consults user handlers before its own dispatch, so neither form
        // reaches the view's `clipboardCopy` / `clipboardRead`. Overriding
        // `clipboardCopy` on the view is not possible from this module (it is
        // `public`, not `open`).
        terminalView.getTerminal().registerOscHandler(code: 52) { _ in }
    }

    /// Starts `executable arguments...` on the pty with a fully specified
    /// environment, for a non-interactive run. A process that is still
    /// running is terminated first. Nothing about the launch is retained.
    func launch(executable: String, arguments: [String], environment: [String: String]) {
        start(kind: .run, executable: executable, arguments: arguments, environment: environment)
    }

    /// Starts the interactive CLI session (or a shell) and remembers the
    /// command so `relaunch()` can start it again.
    func launchInteractive(executable: String, arguments: [String], environment: [String: String]) {
        interactiveLaunch = (executable, arguments, environment)
        start(kind: .interactive, executable: executable, arguments: arguments, environment: environment)
    }

    /// Starts the interactive session again with the command of its last
    /// launch; no-op before the first `launchInteractive`.
    func relaunch() {
        guard let last = interactiveLaunch else { return }
        launchInteractive(executable: last.executable, arguments: last.arguments, environment: last.environment)
    }

    private func start(kind: LaunchKind, executable: String, arguments: [String], environment: [String: String]) {
        if state == .running {
            terminalView.terminate()
        }
        if state != .idle {
            // Clear the previous session's screen before relaunching.
            terminalView.feed(text: "\r\n\u{1b}[2J\u{1b}[H")
        }
        // A new process starts at column 0 with nothing held back from the last one.
        terminalView.filter.reset()
        let env = environment.map { "\($0.key)=\($0.value)" }
        terminalView.startProcess(executable: executable, args: arguments, environment: env, execName: nil)
        lastLaunchKind = kind
        state = .running
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
/// override hands the **raw** bytes to `tap` (the progress parser needs every
/// `@@LSS` event) and renders only what `ProtocolLineFilter` lets through, so
/// the pane never shows protocol lines. SwiftTerm delivers these chunks on the
/// main queue (its `LocalProcess` is created with the default dispatch queue),
/// and the view is main-actor isolated like every `NSView`, so no hop is needed.
///
/// The interactive CLI is unaffected: it never writes `@@LSS ` (the progress
/// protocol exists only in non-interactive mode), so on an interactive pty the
/// filter passes every byte straight through — a false start such as `@@L` at a
/// line start is held for at most five bytes and released on the next one.
final class TappedTerminalView: LocalProcessTerminalView {
    var tap: (@MainActor (ArraySlice<UInt8>) -> Void)?
    /// Reset by `TerminalSession.start` for every new process.
    var filter = ProtocolLineFilter()

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // `super.dataReceived` is `feed(byteArray:)`; feeding the filtered bytes
        // directly keeps the plain override's order: render, then tap.
        let visible = filter.feed(slice)
        if !visible.isEmpty {
            feed(byteArray: visible[...])
        }
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
