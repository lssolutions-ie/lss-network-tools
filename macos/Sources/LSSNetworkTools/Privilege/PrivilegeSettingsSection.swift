import SwiftUI
import ServiceManagement
import LSSXPC

/// Settings → Privileges: helper registration, its health, and how runs get root.
struct PrivilegeSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let installer = model.helperInstaller
        Section {
            LabeledContent("Helper") {
                Label(installer.statusText, systemImage: statusSymbol(installer.status))
                    .foregroundStyle(statusColor(installer.status))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Check") {
                Text(checkText)
                    .foregroundStyle(checkColor)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            if let error = installer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if installer.status == .requiresApproval {
                Text("An administrator must allow “LSS Network Tools” in System Settings → General → Login Items & Extensions (Allow in the Background), then choose Check Again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Register") { model.registerHelper() }
                    .disabled(installer.status == .enabled || model.runCoordinator.isActive)
                Button("Unregister") { model.unregisterHelper() }
                    .disabled(installer.status == .notRegistered || model.runCoordinator.isActive)
                Button("Open Login Items") { installer.openLoginItems() }
                Spacer()
                Button("Check Again") { Task { await model.refreshHelper() } }
                    .disabled(model.helperCheck == .checking)
            }
            Picker("Run tasks with", selection: $model.privilegeMode) {
                ForEach(PrivilegeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text(modeFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The helper runs only the installed lss-network-tools command-line tool, as root, with the same checked flags the app would give sudo. It cannot start other programs, accept paths outside the tool's output folder (apart from reading your own Wi-Fi scan files), or read the app's settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Privileges")
        }
        .task { await model.refreshHelper() }
    }

    private var checkText: String {
        switch model.helperCheck {
        case .unknown: return "Not checked yet"
        case .checking: return "Checking…"
        case .notEnabled: return "Available once the helper is enabled"
        case .ready(let info):
            let build = info.version == LSSHelperBuildVersion ? "" : " (this app is \(LSSHelperBuildVersion))"
            return "Helper \(info.version), protocol \(info.protocolVersion) — ready\(build)"
        case .incompatible(let info):
            return "Helper \(info.version) speaks protocol \(info.protocolVersion); this app needs \(LSSHelperProtocolVersion). Unregister and register again."
        case .unreachable(let message):
            return message
        }
    }

    private var checkColor: Color {
        switch model.helperCheck {
        case .ready: .green
        case .incompatible, .unreachable: .red
        case .unknown, .checking, .notEnabled: .secondary
        }
    }

    private var modeFootnote: String {
        switch model.privilegeMode {
        case .helper:
            return model.isHelperReady
                ? "Runs start without a password; their output still appears in the terminal pane."
                : "Until the helper is enabled and answers, runs fall back to sudo in the terminal pane."
        case .sudoTerminal:
            return "Each run asks for your administrator password in the terminal pane."
        }
    }

    private func statusSymbol(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "checkmark.shield.fill"
        case .requiresApproval: "hand.raised.fill"
        case .notFound: "exclamationmark.triangle.fill"
        default: "shield.slash"
        }
    }

    private func statusColor(_ status: SMAppService.Status) -> Color {
        switch status {
        case .enabled: .green
        case .requiresApproval: .orange
        case .notFound: .red
        default: .secondary
        }
    }
}
