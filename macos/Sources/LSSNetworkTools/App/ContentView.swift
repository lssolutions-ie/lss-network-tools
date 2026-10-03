import SwiftUI
import LSSCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var automationStarted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
        }
        .navigationTitle("LSS Network Tools")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                InterfacePicker()
                VersionBadge()
            }
        }
        .task {
            await model.refresh()
            if !automationStarted {
                automationStarted = true
                await Automation.runIfRequested(model: model)
            }
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.selection ?? .runAudit {
        case .runAudit:
            TerminalScreen(task: nil)
        case .task(let task):
            TerminalScreen(task: task)
        case .previousRuns:
            RunBrowserView()
        case .settings:
            SettingsView()
        }
    }
}

/// The main pane for Run Audit and every task in M1: an optional task header
/// above the shared CLI terminal session.
struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    let task: TaskID?

    var body: some View {
        VStack(spacing: 0) {
            if let task {
                TaskHeader(task: task)
                Divider()
            }
            if model.cli == nil {
                CLIMissingBanner()
                Divider()
            }
            TerminalPane()
        }
    }
}

struct TaskHeader: View {
    let task: TaskID

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: task.symbolName)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("Task \(task.rawValue) — \(task.title)")
                    .font(.title3.weight(.semibold))
                Text(task.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Label(task.group.title, systemImage: "folder")
                    if task.isMultiEntry { Label("One result file per run", systemImage: "doc.on.doc") }
                    if task.isStressTest { Label("Requires confirmation", systemImage: "exclamationmark.triangle") }
                    Label("Output: \(task.outputFile)", systemImage: "curlybraces")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("Run it from the session below: choose option \(task.rawValue) in the main menu.")
                    .font(.callout)
                    .padding(.top, 2)
            }
            Spacer()
        }
        .padding(16)
        .background(.background.secondary)
    }
}

struct CLIMissingBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command-line tool not found", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("LSS Network Tools expects the CLI at /usr/local/share/lss-network-tools (install.env). Install it from the shell below, then choose Settings → Re-detect.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("git clone https://github.com/lssolutions-ie/lss-network-tools.git && cd lss-network-tools && sudo ./install.sh")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button("Re-detect") { Task { await model.refresh(); model.launchTerminal() } }
                Button("Open Settings") { model.selection = .settings }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
    }
}

struct InterfacePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Interface", selection: $model.selectedInterface) {
            if model.interfaces.isEmpty {
                Text("No interfaces").tag("")
            }
            ForEach(model.interfaces) { interface in
                Text(interface.displayName).tag(interface.device)
            }
        }
        .pickerStyle(.menu)
        .help("Interface the audit will use (passed to the CLI in later milestones)")
    }
}

struct VersionBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Text("GUI \(model.guiVersion)")
            Text("·").foregroundStyle(.tertiary)
            if let version = model.cliVersion {
                Text("CLI \(version)")
            } else if model.cli == nil {
                Text("CLI not installed").foregroundStyle(.orange)
            } else {
                Text("CLI —")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .help("GUI version · installed command-line tool version")
    }
}
