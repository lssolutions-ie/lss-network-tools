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
            // The sheet's height is decided here, from the window it is about
            // to be attached to, so the footer never leaves a small window.
            NewRunSheet(request: request, idealHeight: NewRunSheet.preferredHeight())
        }
        .sheet(isPresented: $model.setupPresented) {
            SetupView(idealHeight: SetupView.preferredHeight())
        }
        // Rebuild Report (no sheet) while the interactive CLI is running; the
        // New Run sheet shows the same dialog itself while it is open.
        .endInteractiveSessionAlert(
            isPresented: Binding(
                get: { model.pendingLaunch != nil && model.newRunSheet == nil },
                set: { if !$0 { model.cancelPendingLaunch() } }
            ),
            launch: model.pendingLaunch,
            onConfirm: { model.confirmPendingLaunch() },
            onCancel: { model.cancelPendingLaunch() }
        )
        .task {
            await model.refresh()
            if !automationStarted {
                automationStarted = true
                await Automation.runIfRequested(model: model)
                // `--setup`, or the first launch of this build — never while an
                // automation flag (screenshots, fixtures) drives the window.
                Automation.presentSetupIfNeeded(model: model)
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

extension View {
    /// The confirmation `AppModel.startRun` / `rebuildReport` / `deleteRun` ask
    /// for when the interactive CLI session is running: starting a run, a report
    /// build or a deletion SIGTERMs it, so nothing starts until the user agrees.
    /// The wording follows the parked launch (`launch`).
    func endInteractiveSessionAlert(isPresented: Binding<Bool>, launch: AppModel.PendingLaunch?, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) -> some View {
        let (button, action) = Self.endSessionWording(for: launch)
        return alert("End the interactive CLI session?", isPresented: isPresented) {
            Button(button, role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel, action: onCancel)
        } message: {
            Text("The interactive CLI session is running. \(action) ends it — any scan in progress is lost.")
        }
    }

    /// Button title and the verb phrase of the message for each kind of launch.
    static func endSessionWording(for launch: AppModel.PendingLaunch?) -> (button: String, action: String) {
        switch launch {
        case .report?: ("End Session and Rebuild", "Rebuilding this report")
        case .delete?: ("End Session and Delete", "Deleting this run")
        case .run?, nil: ("End Session and Start", "Starting this run")
        }
    }
}

/// `Text` from a Markdown string (inline code is rendered monospaced); the
/// plain string when it does not parse.
func markdownText(_ markdown: String) -> Text {
    Text((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown))
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
        // No background of its own: every section of the detail pane shares the window
        // background, so the column divider next to the sidebar reads as one continuous
        // line (a tinted header made the edge change tone half-way down).
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
                    .disabled(model.isRefreshing)
                Button("Open Interactive CLI Session") { model.launchTerminal() }
                    .disabled(model.runCoordinator.isActive)
                Button("Open Settings") { model.selection = .settings }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
    }
}

/// Shown on the Run Audit and task screens while the installed CLI predates
/// non-interactive mode (`NonInteractiveSupport.unsupported`): runs cannot
/// start, the interactive session still works with the old tool.
struct CLIUnsupportedBanner: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Runs need a newer command-line tool", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            markdownText(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                Button("Re-detect") { Task { await model.refresh() } }
                    .disabled(model.isRefreshing)
                Button("Open Interactive CLI Session") { model.launchTerminal() }
                    .disabled(model.runCoordinator.isActive)
                Button("Open Settings") { model.selection = .settings }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
    }
}

/// `NonInteractiveSupport.incompatible`: the CLI supports non-interactive
/// runs but lists its tasks differently from this app. A warning — runs are
/// still allowed — with the first few differences; Settings shows them all.
struct CLIDriftBanner: View {
    let reasons: [String]
    private let shown = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The command-line tool lists its tasks differently from this app", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(Array(reasons.prefix(shown).enumerated()), id: \.offset) { _, reason in
                Text("• \(reason)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if reasons.count > shown {
                Text("…and \(reasons.count - shown) more in Settings → Command-line tool.")
                    .foregroundStyle(.secondary)
            }
            Text("Runs can still start; task names or result files may not match what the app expects.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
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
                    .foregroundStyle(model.nonInteractiveGateMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            } else if model.cli == nil {
                Text("CLI not installed").foregroundStyle(.orange)
            } else {
                Text("CLI —")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .help(model.nonInteractiveGateMessage ?? "GUI version · installed command-line tool version")
    }
}
