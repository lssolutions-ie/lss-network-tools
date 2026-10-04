import SwiftUI
import LSSCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var automationStarted = false

    var body: some View {
        @Bindable var model = model
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
        .sheet(item: $model.newRunSheet) { request in
            NewRunSheet(request: request)
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
            RunAuditScreen(task: nil)
        case .task(let task):
            RunAuditScreen(task: task)
        case .previousRuns:
            RunBrowserView()
        case .settings:
            SettingsView()
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
                Text("Start it with “Run Task \(task.rawValue)…” below, or add it to a previous run with “Continue Previous Run…”.")
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
            Text("LSS Network Tools expects the CLI at /usr/local/share/lss-network-tools (install.env). Install it from a shell — “Open Interactive CLI Session” opens one here while the tool is missing — then choose Re-detect.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("git clone https://github.com/lssolutions-ie/lss-network-tools.git && cd lss-network-tools && sudo ./install.sh")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button("Re-detect") { Task { await model.refresh() } }
                Button("Open Interactive CLI Session") { model.launchTerminal() }
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
        .help("Interface new runs audit (preselected in the New Run sheet)")
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
