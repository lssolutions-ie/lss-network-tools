import AppKit
import QuartzCore
import SwiftUI
import LSSCore

/// Command-line automation used by `make screenshot`:
/// `LSSNetworkTools --screenshot out.png [--view audit|task-5|runs|settings] [--delay 3] [--no-exit]`
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
        var delay: Double = 3
        var exitAfter = true
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
        guard let options = parse() else { return }
        if let view = options.view, let item = selection(for: view) {
            model.selection = item
        }
        // A taller window keeps the whole sidebar on screen (no scrolling), which
        // cacheDisplay renders more faithfully than a scrolled list.
        if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
            window.setContentSize(NSSize(width: 1200, height: 880))
            window.center()
        }
        try? await Task.sleep(for: .seconds(options.delay))
        if let path = options.renderDetailPath {
            do {
                try Screenshot.renderDetail(model: model, to: URL(filePath: path))
                NSLog("LSSNetworkTools: detail render written to %@", path)
            } catch {
                NSLog("LSSNetworkTools: detail render failed: %@", String(describing: error))
            }
            if options.exitAfter && options.screenshotPath == nil {
                model.terminal.terminate()
                NSApp.terminate(nil)
            }
        }
        if let path = options.screenshotPath {
            if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
                // Flush pending layout and layer updates so the cached display
                // reflects the current state rather than a stale layer tree.
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
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
                model.terminal.terminate()
                NSApp.terminate(nil)
            }
        }
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
    /// Writes a PNG of the window (title bar, toolbar and content).
    ///
    /// Preferred path: the window server's own image of this window
    /// (`CGWindowListCreateImage`), which capturing our *own* window does not
    /// need Screen Recording permission for and which reflects exactly what is
    /// on screen. Fallback: `cacheDisplay` of the theme frame, which is
    /// permission-free too but mis-renders scrolled `NSScrollView`s.
    static func capture(window: NSWindow, to url: URL) throws {
        let data: Data
        if let cgImage = windowServerImage(of: window) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            data = png
        } else {
            data = try cachedDisplayPNG(of: window)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
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

    private static func windowServerImage(of window: NSWindow) -> CGImage? {
        let windowID = CGWindowID(window.windowNumber)
        guard windowID != 0 else { return nil }
        let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution])
        // Without Screen Recording permission the API returns a blank image or
        // nil for other apps' windows; for our own window it returns real
        // pixels. Treat a tiny image as failure so the fallback runs.
        if let image, image.width > 50, image.height > 50 { return image }
        return nil
    }

    private static func cachedDisplayPNG(of window: NSWindow) throws -> Data {
        guard let content = window.contentView else { throw CocoaError(.featureUnsupported) }
        let target = content.superview ?? content
        target.layoutSubtreeIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
            throw CocoaError(.featureUnsupported)
        }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
