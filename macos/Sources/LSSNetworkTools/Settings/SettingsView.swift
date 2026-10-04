import SwiftUI
import LSSCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Command-line tool") {
                if let cli = model.cli {
                    LabeledContent("Status") {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    LabeledContent("Version", value: model.cliVersion ?? "unknown")
                    LabeledContent("Non-interactive runs") {
                        NonInteractiveSupportLabel(support: model.nonInteractiveSupport, isRefreshing: model.isRefreshing)
                    }
                    if let gate = model.nonInteractiveGateMessage {
                        markdownText(gate)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !model.taskListDrift.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("The tool's task list differs from this app; runs are still allowed:")
                            ForEach(Array(model.taskListDrift.enumerated()), id: \.offset) { _, reason in
                                Text("• \(reason)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    }
                    LabeledContent("Located via", value: cli.source.rawValue)
                    LabeledContent("Script", value: cli.scriptPath.path(percentEncoded: false))
                    LabeledContent("Data root", value: cli.dataRoot.path(percentEncoded: false))
                    LabeledContent("Launcher", value: cli.wrapperPath?.path(percentEncoded: false) ?? "/bin/bash <script>")
                } else {
                    LabeledContent("Status") {
                        Label("Not installed", systemImage: "xmark.octagon.fill").foregroundStyle(.orange)
                    }
                    Text("Expected /usr/local/share/lss-network-tools/install.env, written by install.sh.")
                        .foregroundStyle(.secondary)
                }
                TextField("Developer override (portable checkout path)", text: $model.cliAppRootOverride)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Re-detect") { Task { await model.refresh() } }
                        .disabled(model.isRefreshing)
                    if let last = model.lastRefresh {
                        Text("Checked \(last.formatted(date: .omitted, time: .standard))")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }

            Section("Interface") {
                Picker("Audit interface", selection: $model.selectedInterface) {
                    ForEach(model.interfaces) { interface in
                        Text(interface.displayName).tag(interface.device)
                    }
                }
                if let defaultRoute = model.defaultRouteInterface {
                    LabeledContent("Default route", value: defaultRoute)
                }
                if let details = model.selectedInterfaceDetails {
                    LabeledContent("IPv4", value: details.ipv4 ?? "none")
                    LabeledContent("MAC", value: details.macAddress ?? "n/a")
                }
            }

            Section {
                TextField("Prepared by", text: $model.preparedBy, prompt: Text("Name printed on the PDF cover"))
                Toggle("Skip PDF report by default", isOn: $model.skipPDFByDefault)
                Text("Both prefill the New Run sheet and apply to “Rebuild Report”; each run can still change them (a change in the sheet is not written back here).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Runs")
            }

            PrivilegeSettingsSection()

            Section {
                LabeledContent("State") {
                    // A helper-route run never launches a process in the pane,
                    // so the terminal's own state would read "Idle" mid-run.
                    if model.runCoordinator.isActive {
                        Text(model.runCoordinator.isBuildingReport ? "In use by a report build" : "In use by a run")
                    } else {
                        switch model.terminal.state {
                        case .idle: Text("Idle")
                        case .running: Text("Running")
                        case .exited(let code): Text("Exited (\(code.map(String.init) ?? "?"))")
                        }
                    }
                }
                if !model.terminal.title.isEmpty {
                    LabeledContent("Title", value: model.terminal.title)
                }
                HStack {
                    Button("Open Interactive CLI Session") { model.launchTerminal() }
                        .disabled(model.runCoordinator.isActive)
                    Button("End Session") { model.endTerminalSession() }
                        .disabled(model.terminal.state != .running)
                }
                Text("The interactive menu-driven CLI no longer starts on its own; open it here or from the Terminal menu. New runs use the same pane non-interactively and ask before ending a running interactive session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Interactive CLI")
            }

            Section("About") {
                LabeledContent("GUI version", value: "\(model.guiVersion) (build \(model.guiBuild))")
                LabeledContent("Engine", value: "lss-network-tools.sh — the GUI never reimplements scans")
            }

            UpdatesSettingsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

/// One line for `NonInteractiveSupport` (Settings → Command-line tool).
struct NonInteractiveSupportLabel: View {
    let support: NonInteractiveSupport
    let isRefreshing: Bool

    var body: some View {
        switch support {
        case .unknown:
            if isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…")
                }
            } else {
                Text("Not checked")
            }
        case .supported(let listing):
            Label(supportedText(listing), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unsupported(let version):
            Label("Not supported by \(version ?? "this version") (no --run-task)", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.orange)
        case .incompatible(let reasons):
            Label("Supported, but the task list differs (\(reasons.count) difference\(reasons.count == 1 ? "" : "s"))", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func supportedText(_ listing: CLITaskListing) -> String {
        var text = "Supported — \(listing.tasks.count) tasks listed"
        if let version = listing.version { text += " by \(version)" }
        return text
    }
}
