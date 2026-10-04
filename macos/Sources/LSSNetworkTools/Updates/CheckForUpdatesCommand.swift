import SwiftUI

/// "Check for Updates…" in the app menu. A `View` (not inline in `commands`)
/// so SwiftUI re-renders it when `canCheckForUpdates` changes.
struct CheckForUpdatesCommand: View {
    let updates: SparkleController

    var body: some View {
        if updates.isEnabled {
            button
        } else {
            button.help(SparkleController.notConfiguredExplanation)
        }
    }

    private var button: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
    }
}
