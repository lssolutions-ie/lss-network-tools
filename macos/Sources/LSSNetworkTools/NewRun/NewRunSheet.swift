import AppKit
import SwiftUI
import LSSCore

/// New Run / Continue Run sheet: run context, task selection, task-specific
/// inputs, inline validation and Start (which goes through the stress-consent
/// dialog when the selection includes Task 10, Task 14 or the full audit).
///
/// Sizing: the width is pinned at 640 pt; the height is 720 pt when the
/// window allows and otherwise what fits the window (`preferredHeight`),
/// never below 480 pt. The grouped form scrolls, so the header, the problems
/// strip and the Cancel/Start footer stay on screen at the 980×620 minimum
/// window size.
struct NewRunSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sheetRequest: NewRunSheetRequest
    @State private var draft: RunDraft
    @State private var showConsent = false
    /// Task 17's CoreWLAN scanner; lives as long as the sheet.
    @State private var wifiScanner = WiFiScanner()
    private let idealHeight: CGFloat

    static let fullHeight: CGFloat = 720
    static let minimumHeight: CGFloat = 480
    /// Room left between the sheet and the window's edges when it has to shrink.
    static let windowMargin: CGFloat = 48

    init(request: NewRunSheetRequest, idealHeight: CGFloat = NewRunSheet.fullHeight) {
        sheetRequest = request
        _draft = State(initialValue: request.draft)
        self.idealHeight = min(Self.fullHeight, max(Self.minimumHeight, idealHeight))
    }

    /// The height the sheet should take in front of the document window:
    /// `fullHeight` unless the window's content area is smaller than that
    /// plus `windowMargin`. Computed by the presenter (`ContentView`) when the
    /// sheet is created, before AppKit attaches it.
    @MainActor
    static func preferredHeight() -> CGFloat {
        let candidates = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.sheetParent == nil }
        guard let window = candidates.first(where: \.isKeyWindow) ?? candidates.first else { return fullHeight }
        return min(fullHeight, max(minimumHeight, window.contentLayoutRect.height - windowMargin))
    }

    private var request: RunTaskRequest { draft.request }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                // What to run comes first, then the inputs those tasks need,
                // then where the run is recorded — so a task's own fields are
                // visible without scrolling when the sheet opens for one task.
                Section("Tasks") {
                    // Opened from a task screen → that task is preselected and
                    // the list starts collapsed; otherwise the list is open.
                    TaskSelectionView(
                        draft: $draft,
                        existingTasks: draft.existingRun?.presentTasks ?? [],
                        expanded: sheetRequest.draft.selectedTasks.count != 1
                    )
                }
                if request.requiresTarget {
                    Section("Target") { TargetPanel(draft: $draft) }
                }
                if request.requiresMAC {
                    Section("Device") { MACPanel(draft: $draft) }
                }
                if request.requiresWireless {
                    Section("Wireless room (Task 17)") { WirelessRoomPanel(draft: $draft, scanner: wifiScanner) }
                }
                if request.requiresUniFi {
                    Section("UniFi adoption (Task 19)") { UniFiAdoptionPanel(draft: $draft) }
                }
                contextSection
            }
            .formStyle(.grouped)
            Divider()
            if !problems.isEmpty {
                problemsStrip
                Divider()
            }
            footer
        }
        .frame(width: 640)
        .frame(minHeight: Self.minimumHeight, idealHeight: idealHeight)
        .sheet(isPresented: $showConsent) {
            StressConsentDialog(
                tasks: draft.taskIDs,
                isFullAudit: draft.selectionMode == .fullAudit,
                targetIP: draft.targetIP.trimmed
            ) { consented in
                showConsent = false
                if consented { start(withConsent: true) }
            }
        }
        // Start while the interactive CLI is running: `AppModel.startRun`
        // parks the launch and the sheet stays open until this is answered.
        .endInteractiveSessionAlert(
            isPresented: Binding(
                get: { model.pendingLaunch != nil },
                set: { if !$0 { model.cancelPendingLaunch() } }
            ),
            onConfirm: {
                model.confirmPendingLaunch()
                dismiss()
            },
            onCancel: { model.cancelPendingLaunch() }
        )
        .onAppear {
            guard sheetRequest.presentConsentImmediately else { return }
            // Let the sheet's window appear before attaching a second sheet to it.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                showConsent = true
            }
        }
    }

    // MARK: Validation

    /// Rules that need the app model, appended to `draft.problems`:
    /// * a continued run's directory must still exist (deleted in Finder meanwhile);
    /// * the chosen interface must be present on this Mac now — the engine checks
    ///   `--interface` against its `list_interfaces`, which `NetworkInterfaces.list()` mirrors;
    /// * on the helper route Task 17 needs a CoreWLAN scan from this sheet: the
    ///   privileged helper cannot open LSS-WiFiScan.app, and the coordinator
    ///   refuses to route such a run through it.
    private var sheetProblems: [RunDraft.Problem] {
        var problems: [RunDraft.Problem] = []
        if let run = draft.existingRun {
            var isDirectory: ObjCBool = false
            let path = run.directory.path(percentEncoded: false)
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                problems.append(.sheet("The run directory no longer exists: \(path)"))
            }
        }
        if !draft.interface.isEmpty, !model.interfaces.contains(where: { $0.device == draft.interface }) {
            problems.append(.sheet("Interface “\(draft.interface)” is not present on this Mac — choose one from the list."))
        }
        if request.requiresWireless, draft.wifiScan == nil, model.wouldRouteRunsThroughHelper {
            problems.append(.sheet("Scan this room with CoreWLAN first — the privileged helper cannot open LSS-WiFiScan.app"))
        }
        return problems
    }

    private var problems: [RunDraft.Problem] { draft.problems + sheetProblems }

    private var canStart: Bool { !draft.taskIDs.isEmpty && problems.isEmpty && model.canStartRuns }

    // MARK: Header / footer

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: draft.isContinuing ? "arrow.uturn.forward.circle.fill" : "play.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.isContinuing ? "Continue Run" : "New Run")
                    .font(.title2.weight(.semibold))
                Text(headerSubtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
    }

    private var headerSubtitle: String {
        if let run = draft.existingRun {
            return "Adds tasks to “\(run.title)” — results are written into the existing run directory and its report is rebuilt."
        }
        return "Runs the selected tasks through the command-line tool as root — via the privileged helper when it is enabled in Settings → Privileges, otherwise with sudo (type the password in the terminal pane)."
    }

    /// Inline validation (`ArgumentBuilder.problems` plus the sheet's rules),
    /// kept outside the scrolling form so it is visible whatever the scroll
    /// position.
    private var problemsStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(problems, id: \.self) { problem in
                Label(problem.description, systemImage: "exclamationmark.circle.fill")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            if model.cli == nil {
                Label("The command-line tool is not installed", systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let gate = model.nonInteractiveGateMessage {
                Label {
                    markdownText(gate)
                } icon: {
                    Image(systemName: "xmark.octagon")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            } else if request.requiresConsent {
                Label("Includes a stress test — you will be asked to confirm", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(startTitle) { startTapped() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var startTitle: String {
        let count = draft.taskIDs.count
        switch draft.selectionMode {
        case .fullAudit: return "Start Full Audit"
        case .selected: return count == 1 ? "Start Task \(draft.taskIDs[0].rawValue)" : "Start \(count) Tasks"
        }
    }

    // MARK: Context

    @ViewBuilder
    private var contextSection: some View {
        Section(draft.isContinuing ? "Run" : "Run context") {
            Picker("Interface", selection: $draft.interface) {
                if model.interfaces.isEmpty && draft.interface.isEmpty {
                    Text("No interfaces found").tag("")
                }
                ForEach(model.interfaces) { interface in
                    Text(interfaceLabel(interface)).tag(interface.device)
                }
                if !draft.interface.isEmpty, !model.interfaces.contains(where: { $0.device == draft.interface }) {
                    Text("\(draft.interface) · not present now").tag(draft.interface)
                }
            }
            if let missing = draft.interfaceMissingFromRun {
                Label(
                    draft.interface.isEmpty
                        ? "\(missing) from the run is not present; choose an interface"
                        : "\(missing) from the run is not present; using \(draft.interface)",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let run = draft.existingRun {
                LabeledContent("Client", value: run.client ?? "Unknown")
                LabeledContent("Location", value: run.location ?? "Unknown")
                if let note = run.note, !note.isEmpty {
                    LabeledContent("Note", value: note)
                }
                LabeledContent("Run directory") {
                    Text(run.directory.path(percentEncoded: false))
                        .font(.caption)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            } else {
                TextField("Client", text: $draft.client, prompt: Text("Client or organisation name"))
                TextField("Location", text: $draft.location, prompt: Text("Site, building or office"))
                TextField("Note", text: $draft.note, prompt: Text("Optional — e.g. staff Wi-Fi"))
            }
            TextField("Prepared by", text: $draft.preparedBy, prompt: Text("Name on the PDF cover (optional)"))
                .help("Prefilled from Settings → Runs; a change here applies to this run only")
            Toggle("Skip PDF report", isOn: $draft.skipPDF)
                .help("The TXT report, findings and manifest are always written; this skips only the PDF")
        }
    }

    private func interfaceLabel(_ interface: NetworkInterface) -> String {
        [interface.device, interface.ipv4 ?? "no IPv4", interface.hardwarePort ?? "no hardware port"]
            .joined(separator: " · ")
    }

    // MARK: Starting

    private func startTapped() {
        if request.requiresConsent {
            showConsent = true
        } else {
            start(withConsent: false)
        }
    }

    private func start(withConsent consent: Bool) {
        var request = draft.request
        request.stressConsent = consent
        // A stress run is never queued without the dialog's consent.
        if request.requiresConsent && !consent { return }
        guard canStart else { return }
        model.rememberRunDefaults(from: draft)
        model.startRun(request, sshPassword: draft.sshPasswordForStart)
        // With the interactive session running the model parked the launch;
        // the confirmation dialog above decides, and the sheet stays open so
        // Cancel keeps every entry.
        if model.pendingLaunch == nil {
            dismiss()
        }
    }
}
