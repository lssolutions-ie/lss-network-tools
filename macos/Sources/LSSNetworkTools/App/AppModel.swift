import Foundation
import Observation
import Defaults
import LSSCore

extension Defaults.Keys {
    static let selectedInterface = Key<String>("selectedInterface", default: "")
    static let cliAppRootOverride = Key<String>("cliAppRootOverride", default: "")
}

/// Root view model: CLI location, interfaces, sidebar selection, terminal session.
@MainActor
@Observable
final class AppModel {
    var selection: SidebarItem? = .runAudit

    private(set) var cli: CLIInstall?
    private(set) var cliVersion: String?
    private(set) var interfaces: [NetworkInterface] = []
    private(set) var defaultRouteInterface: String?
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    var selectedInterface: String = Defaults[.selectedInterface] {
        didSet { Defaults[.selectedInterface] = selectedInterface }
    }

    var cliAppRootOverride: String = Defaults[.cliAppRootOverride] {
        didSet { Defaults[.cliAppRootOverride] = cliAppRootOverride }
    }

    let terminal = TerminalSession()
    let runBrowser = RunBrowserModel()

    /// Set by `--output-dir` (automation / fixtures); otherwise the CLI's `output/` is browsed.
    var outputDirectoryOverride: URL?

    /// Points the run browser at the detected CLI's output directory (or the override).
    func configureRunBrowser() {
        runBrowser.configure(outputDirectory: outputDirectoryOverride ?? cli?.outputDirectory, decoder: PayloadDecoding.decode)
    }

    var guiVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var guiBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var selectedInterfaceDetails: NetworkInterface? {
        interfaces.first { $0.device == selectedInterface }
    }

    /// Re-detects the CLI install, its version, and the interface list.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let override = cliAppRootOverride
        let detected = CLIInstall.detect(overrideAppRoot: override.isEmpty ? nil : override)
        cli = detected

        async let interfaceList = NetworkInterfaces.list()
        async let defaultRoute = NetworkInterfaces.defaultRouteInterface()
        async let version: String? = {
            guard let detected else { return nil }
            return await CLIVersionProbe.version(of: detected)
        }()

        interfaces = await interfaceList
        defaultRouteInterface = await defaultRoute
        cliVersion = await version

        if selectedInterface.isEmpty || !interfaces.contains(where: { $0.device == selectedInterface }) {
            selectedInterface = defaultRouteInterface ?? interfaces.first?.device ?? ""
        }

        // The terminal must not start before the CLI has been located, or it
        // would fall back to a plain shell.
        lastRefresh = .now
        launchTerminalIfNeeded()
        configureRunBrowser()
    }

    /// Starts the CLI session in the embedded terminal if nothing is running
    /// yet. No-op until the first `refresh()` has completed.
    func launchTerminalIfNeeded() {
        guard lastRefresh != nil, terminal.state == .idle else { return }
        launchTerminal()
    }

    /// (Re)starts the embedded terminal: `sudo <wrapper>` when the CLI is
    /// installed, otherwise a login shell so the user can install it.
    func launchTerminal() {
        var environment = ProcessRunner.baseEnvironment
        environment["TERM_PROGRAM"] = "LSSNetworkTools"
        if let cli {
            let command = cli.launchCommand
            terminal.launch(
                executable: "/usr/bin/sudo",
                arguments: [command.executable] + command.arguments,
                environment: environment
            )
        } else {
            terminal.launch(executable: "/bin/zsh", arguments: ["-l"], environment: environment)
        }
    }
}
