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
                Text("Both prefill the New Run sheet and apply to “Rebuild Report”; each run can still change them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Runs")
            }

            PrivilegeSettingsSection()

            Section {
                LabeledContent("State") {
                    switch model.terminal.state {
                    case .idle: Text("Idle")
                    case .running: Text(model.runCoordinator.isActive ? "Running a non-interactive run" : "Running")
                    case .exited(let code): Text("Exited (\(code.map(String.init) ?? "?"))")
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
                Text("The interactive menu-driven CLI no longer starts on its own; open it here or from the Terminal menu. New runs use the same pane non-interactively.")
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
