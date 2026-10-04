import AppKit
import QuartzCore
import SwiftUI
import LSSCore
import LSSXPC

/// Command-line automation used by `make screenshot`:
/// `LSSNetworkTools --screenshot out.png [--view audit|task-5|runs|settings|new-run|consent|setup]
///   [--task N] [--output-dir DIR] [--select-run N] [--tab overview|tasks|report] [--collapse-grid]
///   [--simulate-progress FILE [--simulate-interval MS]]
///   [--window-width W] [--window-height H] [--assume-helper-route] [--delay 3] [--no-exit]`
///
/// `--view new-run` opens the New Run sheet (full audit; `--task N` preselects
/// task N), `--view consent` opens it with the stress-consent dialog showing,
/// `--view setup` opens the Setup & Permissions sheet,
/// `--view session-guard` starts the interactive CLI and then requests a run
/// so the "End the interactive CLI session?" confirmation shows, and
/// `--simulate-progress` replays a `@@LSS` fixture stream through the run
/// coordinator on the Run Audit screen.
///
/// `--assume-helper-route` (verification only) makes the New Run sheet apply
/// the helper route's rules — Task 17 without a CoreWLAN scan is a problem —
/// although the helper is not enabled on this Mac; SMAppService status cannot
/// be faked, and nothing is loosened by it.
///
/// Privileged-helper verification (print to stderr, then exit; `--no-exit` does
/// not apply):
/// * `--helper-status` — SMAppService status, the helper's `version()`, its
///   `toolchainTrust()` verdict and the authentication cadence; exit 0 when the
///   helper is enabled and answers with this app's protocol.
/// * `--register-helper` — `SMAppService.register()` once, the outcome verbatim
///   and the status after it; exit 0 when register() did not throw.
/// * `--unregister-helper` — `SMAppService.unregister()` once (used by
///   `scripts/install-app.sh` on every copy before the installed one is
///   registered); exit 0 when it succeeded or nothing was registered.
///
/// `--setup` (no exit) presents the Setup & Permissions sheet after launch —
/// what `make install` opens the installed app with. Without any flag the
/// sheet opens on its own on the first launch of a build (`SetupModel`).
///
/// The window renders itself with `cacheDisplay`, so no Screen Recording
/// permission is needed (unlike `screencapture`).
@MainActor
enum Automation {
    struct Options {
        var screenshotPath: String?
        /// Renders only the SwiftUI detail column with `ImageRenderer` (platform
        /// views such as the terminal are left blank) — a faithful check of the
        /// SwiftUI layout when a window capture is not possible.
        var renderDetailPath: String?
        var view: String?
        /// Run browser: select the n-th run (0 = newest), a detail tab and a task cell.
        var selectRun: Int?
        var tab: String?
        var task: Int?
        /// Hide the task grid so the selected task's results fill the pane.
        var collapseGrid = false
        /// Scroll every vertical scroll view in the window — and in any sheet attached
        /// to it — to its end before capturing (long Settings forms, task views and
        /// sheet sections below the fold).
        var scrollToEnd = false
        /// Browse this directory of runs instead of the CLI's output directory (fixtures, demos).
        var outputDirectory: String?
        /// Replay this `@@LSS` stream (one line per `simulateInterval` ms) instead of running the CLI.
        var simulateProgress: String?
        var simulateInterval: Double = 150
        /// Pretend a run would take the privileged-helper route (sheet rules only).
        var assumeHelperRoute = false
        var delay: Double = 3
        var exitAfter = true
        /// Window content size used while capturing (tall windows show charts below the fold).
        var windowWidth: Double = 1200
        var windowHeight: Double = 880
    }

    static func parse(_ arguments: [String] = CommandLine.arguments) -> Options? {
        var options = Options()
        var requested = false
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--screenshot":
                options.screenshotPath = iterator.next()
                requested = true
            case "--render-detail":
                options.renderDetailPath = iterator.next()
                requested = true
            case "--view":
                options.view = iterator.next()
                requested = true
            case "--output-dir":
                options.outputDirectory = iterator.next()
                requested = true
            case "--simulate-progress":
                options.simulateProgress = iterator.next()
                requested = true
            case "--simulate-interval":
                options.simulateInterval = Double(iterator.next() ?? "") ?? 150
            case "--select-run":
                options.selectRun = Int(iterator.next() ?? "")
            case "--tab":
                options.tab = iterator.next()
            case "--task":
                options.task = Int(iterator.next() ?? "")
            case "--collapse-grid":
                options.collapseGrid = true
            case "--scroll-to-end":
                options.scrollToEnd = true
            case "--assume-helper-route":
                options.assumeHelperRoute = true
            case "--window-height":
                options.windowHeight = Double(iterator.next() ?? "") ?? 880
            case "--window-width":
                options.windowWidth = Double(iterator.next() ?? "") ?? 1200
            case "--delay":
                options.delay = Double(iterator.next() ?? "") ?? 3
            case "--no-exit":
                options.exitAfter = false
            default:
                continue
            }
        }
        return requested ? options : nil
    }

    static func runIfRequested(model: AppModel) async {
        let arguments = CommandLine.arguments
        if arguments.contains("--unregister-helper") {
            await unregisterHelper(model: model)
        }
        if arguments.contains("--register-helper") {
            await registerHelper(model: model)
        }
        if arguments.contains("--helper-status") {
            await printHelperStatus(model: model)
        }
        guard let options = parse() else { return }
        // Size the window before anything attaches a sheet to it: a taller
        // window keeps the whole sidebar on screen (no scrolling), which the
        // capture renders more faithfully than a scrolled list.
        if let window = mainWindow() {
            window.setContentSize(NSSize(width: options.windowWidth, height: options.windowHeight))
            window.center()
            try? await Task.sleep(for: .milliseconds(300))
        }
        if let directory = options.outputDirectory {
            model.outputDirectoryOverride = URL(filePath: directory, directoryHint: .isDirectory)
            model.configureRunBrowser()
        }
        if options.assumeHelperRoute {
            model.assumeHelperRouteForAutomation = true
        }
        let task = options.task.flatMap(TaskID.init(rawValue:))
        if let view = options.view {
            switch view.lowercased() {
            case "new-run", "newrun":
                model.selection = task.map(SidebarItem.task) ?? .runAudit
                model.presentNewRun(task: task)
            case "consent":
                // Full audit (which includes Task 10) unless a task is named;
                // the dialog opens as soon as the sheet is on screen.
                model.selection = .runAudit
                var request = NewRunSheetRequest(draft: model.makeDraft(task: task, existingRun: nil))
                request.presentConsentImmediately = true
                model.newRunSheet = request
            case "setup":
                model.selection = .runAudit
                model.presentSetup()
            case "session-guard":
                // Verification of the interactive-session guard: the interactive
                // CLI starts (sudo waits for a password on the pty, nothing runs),
                // the New Run sheet opens, and a run is requested through the
                // model — `AppModel.startRun` parks it and the "End the
                // interactive CLI session?" dialog shows instead of a SIGTERM.
                // The parked request has no consent and no client, so even a
                // confirmation here could not launch anything.
                model.selection = .runAudit
                model.launchTerminal()
                try? await Task.sleep(for: .milliseconds(1200))
                model.presentNewRun()
                try? await Task.sleep(for: .milliseconds(700))
                model.startRun(model.makeDraft(task: nil, existingRun: nil).request, sshPassword: nil)
            default:
                if let item = selection(for: view) {
                    model.selection = item
                }
            }
        }
        if let path = options.simulateProgress {
            if let data = try? Data(contentsOf: URL(filePath: path)) {
                model.selection = .runAudit
                model.runCoordinator.simulate(stream: data, interval: .milliseconds(max(options.simulateInterval, 0)))
            } else {
                NSLog("LSSNetworkTools: cannot read progress fixture at %@", path)
            }
        }
        if let index = options.selectRun {
            // Wait for the run list, then drive the browser.
            let browser = model.runBrowser
            for _ in 0..<50 where !browser.hasLoadedOnce {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if browser.runs.indices.contains(index) {
                browser.selectedRunID = browser.runs[index].id
                for _ in 0..<50 where browser.detail == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            if let tab = options.tab, let detailTab = RunDetailTab(rawValue: tab.capitalized) {
                browser.detailTab = detailTab
            }
            if let task {
                browser.selectedTask = task
            }
            if options.collapseGrid {
                browser.isGridCollapsed = true
            }
        }
        try? await Task.sleep(for: .seconds(options.delay))
        if options.scrollToEnd, let window = mainWindow() {
            // The window and any sheet attached to it (the New Run sheet's form
            // scrolls too, and its lower sections are what a check often needs).
            for target in Screenshot.windowStack(from: window) {
                Screenshot.scrollToEnd(in: target.contentView)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let path = options.renderDetailPath {
            do {
                try Screenshot.renderDetail(model: model, to: URL(filePath: path))
                NSLog("LSSNetworkTools: detail render written to %@", path)
            } catch {
                NSLog("LSSNetworkTools: detail render failed: %@", String(describing: error))
            }
            if options.exitAfter && options.screenshotPath == nil {
                quit(model: model)
            }
        }
        if let path = options.screenshotPath {
            if let window = mainWindow() {
                // Flush pending layout and layer updates so the cached display
                // reflects the current state rather than a stale layer tree.
                for target in Screenshot.windowStack(from: window) {
                    target.contentView?.layoutSubtreeIfNeeded()
                    target.displayIfNeeded()
                }
                CATransaction.flush()
                try? await Task.sleep(for: .milliseconds(400))
                do {
                    try Screenshot.capture(window: window, to: URL(filePath: path))
                    NSLog("LSSNetworkTools: screenshot written to %@", path)
                } catch {
                    NSLog("LSSNetworkTools: screenshot failed: %@", String(describing: error))
                }
            } else {
                NSLog("LSSNetworkTools: no visible window to capture")
            }
            if options.exitAfter {
                quit(model: model)
            }
        }
    }

    // MARK: Setup sheet

    /// After `runIfRequested` returned (so never in a `--register-helper` /
    /// `--helper-status` / `--unregister-helper` process, which exit): `--setup`
    /// presents the Setup & Permissions sheet; otherwise it opens on the first
    /// launch of this build unless an automation flag is driving the window.
    static func presentSetupIfNeeded(model: AppModel) {
        if CommandLine.arguments.contains("--setup") {
            model.presentSetup(automatic: true)
        } else if parse() == nil, SetupModel.isFirstLaunch(ofBuild: model.guiBuild) {
            // `refresh()` may have taken seconds (helper probes); a New Run sheet the
            // user opened meanwhile is kept, and the Setup sheet waits for the next launch.
            model.presentSetup(automatic: true)
        }
    }

    // MARK: Privileged helper

    /// `--unregister-helper`: one `unregister()` call. Exit 0 when it succeeded or there
    /// was nothing to unregister (`.notRegistered` / `.notFound`), 1 when it threw.
    private static func unregisterHelper(model: AppModel) async -> Never {
        let installer = model.helperInstaller
        installer.refresh()
        let before = installer.status
        report("SMAppService status before: \(HelperInstaller.name(for: before)) (\(before.rawValue))")
        var succeeded: Bool
        switch before {
        case .notRegistered, .notFound:
            report("unregister(): nothing registered from this copy; nothing to do")
            succeeded = true
        default:
            model.helperClient.reset()
            succeeded = installer.unregister()
            if succeeded {
                report("unregister(): succeeded")
            } else {
                report("unregister() failed: \(installer.lastError ?? "unknown error")")
            }
        }
        report("SMAppService status after: \(HelperInstaller.name(for: installer.status)) (\(installer.status.rawValue)) — \(installer.statusText)")
        exit(succeeded ? 0 : 1)
    }

    /// `--helper-status`: prints the SMAppService status, `version()`, the helper's
    /// tool-chain verdict and the authentication cadence to stderr, exits.
    private static func printHelperStatus(model: AppModel) async -> Never {
        let installer = model.helperInstaller
        installer.refresh()
        report("plist \(HelperInstaller.plistName) in \(Bundle.main.bundlePath)")
        report("SMAppService status: \(HelperInstaller.name(for: installer.status)) (\(installer.status.rawValue)) — \(installer.statusText)")
        report("app team identifier: \(HelperClient.ownTeamIdentifier ?? "none (ad-hoc signature)")")
        var ready = false
        if installer.status == .enabled {
            do {
                let info = try await model.helperClient.version()
                ready = info.isCompatible
                report("version(): helper \(info.version), protocol \(info.protocolVersion) (app expects \(LSSHelperProtocolVersion), app helper build \(LSSHelperBuildVersion)) — \(info.isCompatible ? "ready" : "INCOMPATIBLE")")
            } catch {
                report("version() failed: \(error.localizedDescription)")
            }
            if ready {
                do {
                    switch try await model.helperClient.toolchainTrust() {
                    case .trusted:
                        report("toolchainTrust(): trusted — runs need no password")
                    case .untrusted(let reason):
                        report("toolchainTrust(): user-owned — administrator authentication required: \(reason)")
                    case .unusable(let reason):
                        report("toolchainTrust(): cannot run — \(reason)")
                    }
                } catch {
                    report("toolchainTrust() failed: \(error.localizedDescription)")
                }
            }
        } else {
            report("version(): not attempted (status is not enabled)")
        }
        let cadence = model.helperAuthenticationCadence
        report("authentication cadence: \(cadence.rawValue) (\(cadence.title); right \(cadence.right))")
        exit(ready ? 0 : 1)
    }

    /// `--register-helper`: one `register()` call, its outcome verbatim, the status after.
    /// Exit 0 unless the registration failed outright (pending approval counts as done).
    private static func registerHelper(model: AppModel) async -> Never {
        let installer = model.helperInstaller
        installer.refresh()
        report("SMAppService status before: \(HelperInstaller.name(for: installer.status)) (\(installer.status.rawValue))")
        let outcome = installer.register()
        let succeeded: Bool
        switch outcome {
        case .enabled:
            report("register(): succeeded; the helper is enabled")
            succeeded = true
        case .needsApproval(let thrown):
            if let thrown { report("register() threw: \(thrown)") } else { report("register(): returned without error") }
            report("outcome: recorded, waiting for approval in System Settings → General → Login Items & Extensions")
            succeeded = true
        case .failed(let message):
            report("register() failed: \(message)")
            succeeded = false
        }
        report("SMAppService status after: \(HelperInstaller.name(for: installer.status)) (\(installer.status.rawValue)) — \(installer.statusText)")
        if installer.status == .enabled {
            do {
                let info = try await model.helperClient.version()
                report("version(): helper \(info.version), protocol \(info.protocolVersion)")
            } catch {
                report("version() failed: \(error.localizedDescription)")
            }
        }
        exit(succeeded ? 0 : 1)
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data("helper: \(line)\n".utf8))
    }

    /// Ends the automation run. `NSApp.terminate` is deferred by AppKit while
    /// a sheet is attached to the window (it returns instead of exiting), so
    /// the process exits explicitly: there is nothing to save.
    private static func quit(model: AppModel) -> Never {
        model.runCoordinator.cancel()
        model.terminal.terminate()
        NSApp.terminate(nil)
        exit(0)
    }

    /// The document window (never a sheet or panel).
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.sheetParent == nil }
    }

    static func selection(for name: String) -> SidebarItem? {
        switch name.lowercased() {
        case "audit", "run-audit", "terminal": return .runAudit
        case "runs", "previous-runs": return .previousRuns
        case "settings": return .settings
        default:
            if name.lowercased().hasPrefix("task-"), let number = Int(name.dropFirst(5)), let task = TaskID(rawValue: number) {
                return .task(task)
            }
            return nil
        }
    }
}

@MainActor
enum Screenshot {
    /// Writes a PNG of the window (title bar, toolbar and content) together
    /// with any sheet attached to it — sheets are separate windows, so a
    /// capture of the main window alone would miss the New Run sheet.
    ///
    /// Preferred path: the window server's own image of these windows, which
    /// capturing our *own* windows does not need Screen Recording permission
    /// for and which reflects exactly what is on screen. Fallback:
    /// `cacheDisplay` of each window's theme frame composited at the windows'
    /// relative positions; permission-free too but it mis-renders scrolled
    /// `NSScrollView`s.
    static func capture(window: NSWindow, to url: URL) throws {
        let windows = windowStack(from: window)
        let data: Data
        if let cgImage = WindowServerCapture.image(of: windows) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            data = png
        } else {
            data = try cachedDisplayPNG(of: windows)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// The window followed by its chain of attached sheets (a sheet may itself
    /// present a sheet: the consent dialog on top of the New Run sheet).
    /// Scrolls every vertical `NSScrollView` under `root` to its end (outline views, i.e. the sidebar, excluded).
    static func scrollToEnd(in root: NSView?) {
        guard let root else { return }
        if let scrollView = root as? NSScrollView,
           let document = scrollView.documentView,
           !(document is NSOutlineView),
           document.frame.height > scrollView.contentView.bounds.height {
            let clip = scrollView.contentView
            let bottom = NSPoint(x: clip.bounds.origin.x, y: max(0, document.frame.height - clip.bounds.height))
            clip.scroll(to: document.isFlipped ? bottom : NSPoint(x: bottom.x, y: 0))
            scrollView.reflectScrolledClipView(clip)
        }
        for subview in root.subviews {
            scrollToEnd(in: subview)
        }
    }

    static func windowStack(from window: NSWindow) -> [NSWindow] {
        var stack = [window]
        var sheet = window.attachedSheet
        while let current = sheet, !stack.contains(current) {
            stack.append(current)
            sheet = current.attachedSheet
        }
        return stack
    }

    /// Renders the SwiftUI detail column (not the terminal's NSView) at 1200×880.
    static func renderDetail(model: AppModel, to url: URL) throws {
        let view = DetailView()
            .environment(model)
            .frame(width: 900, height: 820)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { throw CocoaError(.featureUnsupported) }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }

    /// Composites each window's cached display at its screen position
    /// (relative to the union of all frames), rendered at the main window's
    /// backing scale.
    private static func cachedDisplayPNG(of windows: [NSWindow]) throws -> Data {
        var pieces: [(rep: NSBitmapImageRep, frame: NSRect)] = []
        for window in windows {
            guard let content = window.contentView else { continue }
            let target = content.superview ?? content
            target.layoutSubtreeIfNeeded()
            guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { continue }
            target.cacheDisplay(in: target.bounds, to: rep)
            pieces.append((rep, window.frame))
        }
        guard let first = pieces.first else { throw CocoaError(.featureUnsupported) }
        let union = pieces.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let scale = windows.first?.backingScaleFactor ?? 2
        let composite = NSImage(size: union.size, flipped: false) { _ in
            for piece in pieces {
                let origin = NSPoint(x: piece.frame.minX - union.minX, y: piece.frame.minY - union.minY)
                piece.rep.draw(in: NSRect(origin: origin, size: piece.frame.size))
            }
            return true
        }
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        guard let cgImage = composite.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: transform]) else {
            throw CocoaError(.featureUnsupported)
        }
        guard let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}

/// `CGWindowListCreateImageFromArray`, looked up at runtime. The function is
/// deprecated since macOS 14 in favour of ScreenCaptureKit — which needs the
/// Screen Recording permission even for the app's own windows, so it cannot
/// replace it here. Binding the symbol with `dlsym` keeps the build free of
/// deprecation warnings and degrades to the `cacheDisplay` fallback should the
/// symbol ever disappear.
@MainActor
private enum WindowServerCapture {
    private typealias CreateImageFromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    private static let createImageFromArray: CreateImageFromArray? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImageFromArray") else { return nil }
        return unsafeBitCast(symbol, to: CreateImageFromArray.self)
    }()

    /// One image covering the union of the windows' bounds (nil when the
    /// window server refuses or returns a blank image).
    static func image(of windows: [NSWindow]) -> CGImage? {
        guard let create = createImageFromArray else { return nil }
        let ids = windows.map(\.windowNumber).filter { $0 > 0 }.map { NSNumber(value: UInt32($0)) }
        guard !ids.isEmpty else { return nil }
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        guard let image = create(.null, ids as CFArray, options.rawValue)?.takeRetainedValue() else { return nil }
        // Without Screen Recording permission the API returns a blank image or
        // nil for other apps' windows; for our own windows it returns real
        // pixels. Treat a tiny image as failure so the fallback runs.
        guard image.width > 50, image.height > 50 else { return nil }
        return image
    }
}
