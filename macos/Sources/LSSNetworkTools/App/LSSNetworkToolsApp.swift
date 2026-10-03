import SwiftUI

@main
struct LSSNetworkToolsApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("LSS Network Tools") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Terminal") {
                Button("Relaunch CLI Session") { model.launchTerminal() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("End CLI Session") { model.terminal.terminate() }
                    .keyboardShortcut(".", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 560)
        }
    }
}
