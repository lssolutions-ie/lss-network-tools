import SwiftUI
import LSSCore

/// New Run / Continue Run sheet: run context, task selection, task-specific
/// inputs, inline validation and Start (which goes through the stress-consent
/// dialog when the selection includes Task 10, Task 14 or the full audit).
struct NewRunSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sheetRequest: NewRunSheetRequest
    @State private var draft: RunDraft
    @State private var showConsent = false

    init(request: NewRunSheetRequest) {
        sheetRequest = request
        _draft = State(initialValue: request.draft)
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
                    Section("Wireless room (Task 17)") { WirelessRoomPanel(draft: $draft) }
                }
                if request.requiresUniFi {
                    Section("UniFi adoption (Task 19)") { UniFiAdoptionPanel(draft: $draft) }
                }
                contextSection
            }
            .formStyle(.grouped)
            Divider()
            if !draft.problems.isEmpty {
                problemsStrip
                Divider()
            }
            footer
        }
        .frame(width: 640, height: 720)
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
        .onAppear {
            guard sheetRequest.presentConsentImmediately else { return }
            // Let the sheet's window appear before attaching a second sheet to it.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                showConsent = true
            }
        }
    }

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
        return "Runs the selected tasks through the command-line tool as root. If sudo asks for your password, type it in the terminal pane."
    }

    /// Inline validation (`ArgumentBuilder.problems`), kept outside the
    /// scrolling form so it is visible whatever the scroll position.
    private var problemsStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(draft.problems, id: \.self) { problem in
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
        HStack(spacing: 12) {
            if request.requiresConsent {
                Label("Includes a stress test — you will be asked to confirm", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.cli == nil {
                Label("The command-line tool is not installed", systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(startTitle) { startTapped() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canStart || model.cli == nil)
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
                    Text("\(draft.interface) · from the run's manifest · not present now").tag(draft.interface)
                }
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
        model.rememberRunDefaults(from: draft)
        model.startRun(request, sshPassword: draft.sshPasswordForStart)
        dismiss()
    }
}
