import SwiftUI

@main
struct LSSNetworkToolsApp: App {
    @State private var model = AppModel()
    /// Created with the app so a configured build starts Sparkle at launch
    /// (an unkeyed build never starts it); see `SparkleController`.
    private let updates = SparkleController.shared

    var body: some Scene {
        WindowGroup("LSS Network Tools") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updates: updates)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Run…") { model.presentNewRun() }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(model.cli == nil || model.runCoordinator.isActive)
            }
            CommandMenu("Run") {
                Button("Cancel Run") { model.runCoordinator.cancel() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!model.runCoordinator.isActive)
                Button("Show Previous Runs") { model.selection = .previousRuns }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandMenu("Terminal") {
                Button("Open Interactive CLI Session") { model.launchTerminal() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.runCoordinator.isActive)
                Button("End CLI Session") { model.endTerminalSession() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(model.terminal.state != .running)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 560)
        }
    }
}
