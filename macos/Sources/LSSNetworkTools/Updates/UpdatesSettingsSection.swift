import SwiftUI

/// Settings → "Updates". A `Section` for the Settings `Form`:
/// `UpdatesSettingsSection()` (uses `SparkleController.shared`).
struct UpdatesSettingsSection: View {
    private let updates: SparkleController

    init(updates: SparkleController = .shared) {
        self.updates = updates
    }

    var body: some View {
        @Bindable var updates = updates
        Section("Updates") {
            LabeledContent("Status") {
                if updates.isEnabled {
                    Label("Enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Not configured", systemImage: "minus.circle.fill").foregroundStyle(.secondary)
                }
            }
            if !updates.isEnabled {
                Text(SparkleController.notConfiguredExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Feed") {
                Text(updates.feedURL?.absoluteString ?? "Not set (SUFeedURL is missing from Info.plist)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            Toggle("Check for updates automatically", isOn: $updates.automaticChecksEnabled)
                .disabled(!updates.isEnabled)
            LabeledContent("Last checked", value: lastChecked)
            HStack {
                Spacer()
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
        }
    }

    private var lastChecked: String {
        guard updates.isEnabled else { return "Never (updates are off)" }
        guard let date = updates.lastUpdateCheckDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
