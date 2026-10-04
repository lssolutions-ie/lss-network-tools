import SwiftUI
import LSSCore

/// Tabs for one run: Overview (findings + hints), Tasks (grid + task detail), Report (PDF).
struct RunDetailView: View {
    @Environment(AppModel.self) private var model
    let detail: RunDetail

    var body: some View {
        @Bindable var browser = model.runBrowser
        VStack(spacing: 0) {
            RunHeader(summary: detail.summary)
            Divider()
            Picker("Section", selection: $browser.detailTab) {
                ForEach(RunDetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            switch browser.detailTab {
            case .overview: OverviewTab(detail: detail)
            case .tasks: TasksTab(detail: detail)
            case .report: ReportTab(summary: detail.summary)
            }
        }
    }
}

struct RunHeader: View {
    @Environment(AppModel.self) private var model
    let summary: RunSummary

    var body: some View {
        let runsDisabled = model.cli == nil || model.runCoordinator.isActive
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title).font(.title2.weight(.semibold))
                HStack(spacing: 14) {
                    if let date = summary.generatedAt {
                        Label(date.formatted(date: .long, time: .shortened), systemImage: "calendar")
                    } else if let text = summary.generatedAtText {
                        Label(text, systemImage: "calendar")
                    }
                    if let interface = summary.interface {
                        Label(interface, systemImage: "network")
                    }
                    if let note = summary.note, !note.isEmpty {
                        Label(note, systemImage: "note.text")
                    }
                    if let preparedBy = summary.preparedBy {
                        Label(preparedBy, systemImage: "person")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Text(summary.directory.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    model.presentContinueRun(summary)
                } label: {
                    Label("Continue Run…", systemImage: "arrow.uturn.forward")
                }
                .disabled(runsDisabled)
                .help("Add tasks to this run directory (--run-dir); the interface comes from the run's manifest")
                Button {
                    model.rebuildReport(for: summary)
                } label: {
                    Label("Rebuild Report", systemImage: "doc.badge.gearshape")
                }
                .disabled(runsDisabled)
                .help("Rebuild the TXT report, findings, manifest and PDF for this run (--build-report)")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([summary.directory])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }
        }
        .padding(16)
    }
}

// MARK: - Overview

struct OverviewTab: View {
    let detail: RunDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SummaryStrip(detail: detail)
                if detail.summary.unreadableCount > 0 {
                    LockedFilesBanner(runDirectory: detail.summary.directory, count: detail.summary.unreadableCount)
                }
                SectionCard("Findings", subtitle: detail.findings.isEmpty ? nil : "\(detail.findings.count) finding\(detail.findings.count == 1 ? "" : "s"), highest severity first") {
                    if detail.findings.isEmpty {
                        Text(detail.summary.reportTXT == nil
                             ? "No findings file yet — findings are written when the report is built."
                             : "No findings were recorded for this run.")
                            .foregroundStyle(.secondary)
                    } else {
                        FindingsTable(findings: detail.findings)
                            .frame(minHeight: 160, idealHeight: CGFloat(detail.findings.count) * 58 + 40, maxHeight: 520)
                    }
                }
                if !detail.hints.isEmpty {
                    SectionCard("Remediation hints") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(detail.hints) { hint in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hint.title ?? "Hint").font(.headline)
                                    if let detail = hint.detail {
                                        Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

struct SummaryStrip: View {
    let detail: RunDetail

    private var counts: (ok: Int, warn: Int, failed: Int, skipped: Int, locked: Int) {
        var ok = 0, warn = 0, failed = 0, skipped = 0, locked = 0
        for file in detail.files {
            switch file.state {
            case .unreadable: locked += 1
            case .corrupt: failed += 1
            default:
                switch file.state.envelope?.effectiveStatus {
                case .success?: ok += 1
                case .completedWithWarnings?: warn += 1
                case .failed?: failed += 1
                case .skipped?: skipped += 1
                default: ok += 1
                }
            }
        }
        return (ok, warn, failed, skipped, locked)
    }

    var body: some View {
        let c = counts
        HStack(spacing: 12) {
            StatTile(value: "\(detail.summary.presentTasks.count)", label: "tasks run", color: .blue)
            StatTile(value: "\(c.ok)", label: "succeeded", color: .green)
            StatTile(value: "\(c.warn)", label: "with warnings", color: .orange)
            StatTile(value: "\(c.failed)", label: "failed", color: .red)
            if c.skipped > 0 { StatTile(value: "\(c.skipped)", label: "skipped", color: .gray) }
            if c.locked > 0 { StatTile(value: "\(c.locked)", label: "need elevation", color: .orange) }
            StatTile(value: "\(detail.findings.filter { $0.severity == .high }.count)", label: "high findings", color: .red)
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title.weight(.semibold)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct FindingsTable: View {
    let findings: [Finding]
    @State private var sortOrder = [KeyPathComparator(\Finding.rankForSort)]

    var body: some View {
        Table(findings.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Severity", value: \.rankForSort) { finding in
                SeverityBadge(severity: finding.severity)
            }
            .width(88)
            TableColumn("Finding", value: \.titleForSort) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title ?? "Untitled").font(.body.weight(.medium))
                    if let detail = finding.detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 280)
            TableColumn("Task", value: \.sourceForSort) { finding in
                if let task = finding.task {
                    Text("\(task.rawValue). \(task.title)").foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(finding.source ?? "").foregroundStyle(.secondary)
                }
            }
            .width(min: 120, ideal: 150, max: 180)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

extension Finding {
    var rankForSort: Int { severity?.rank ?? 99 }
    var titleForSort: String { title ?? "" }
    var sourceForSort: String { task.map { String(format: "%02d", $0.rawValue) } ?? (source ?? "zz") }
}

struct SeverityBadge: View {
    let severity: FindingSeverity?

    var body: some View {
        Text(severity?.rawValue.capitalized ?? "—")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch severity {
        case .high?: .red
        case .warning?: .orange
        case .info?: .blue
        case .advice?: .gray
        default: .secondary
        }
    }
}

// MARK: - Tasks

struct TasksTab: View {
    @Environment(AppModel.self) private var model
    let detail: RunDetail

    var body: some View {
        @Bindable var browser = model.runBrowser
        VStack(spacing: 0) {
            if browser.isGridCollapsed {
                collapsedBar
                Divider()
                selectedTaskView(browser.selectedTask)
            } else {
                VSplitView {
                    VStack(spacing: 0) {
                        gridHeader
                        ScrollView {
                            TaskGridView(detail: detail, selection: $browser.selectedTask)
                                .padding([.horizontal, .bottom], 16)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 150, idealHeight: 300, maxHeight: 450)
                    selectedTaskView(browser.selectedTask)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tasksWithFiles: [TaskID] {
        TaskID.allCases.filter { !detail.files(for: $0).isEmpty }
    }

    /// Title row above the grid with the "Hide grid" control.
    private var gridHeader: some View {
        @Bindable var browser = model.runBrowser
        return HStack {
            Text("Task completion").font(.headline)
            Text("\(tasksWithFiles.count) of \(TaskID.allCases.count) tasks have results")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation { browser.isGridCollapsed = true }
            } label: {
                Label("Hide grid", systemImage: "chevron.up")
            }
            .controlSize(.small)
            .disabled(browser.selectedTask == nil)
            .help("Give the selected task's results the full height")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Compact replacement for the grid: a task picker and the "Show grid" control.
    private var collapsedBar: some View {
        @Bindable var browser = model.runBrowser
        return HStack(spacing: 12) {
            Picker("Task", selection: $browser.selectedTask) {
                ForEach(tasksWithFiles) { task in
                    Text("\(task.rawValue). \(task.title)").tag(Optional(task))
                }
            }
            .frame(maxWidth: 380)
            Spacer()
            Button {
                withAnimation { browser.isGridCollapsed = false }
            } label: {
                Label("Show grid", systemImage: "square.grid.3x3")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func selectedTaskView(_ task: TaskID?) -> some View {
        Group {
            if let task {
                TaskFilesView(task: task, files: detail.files(for: task))
            } else {
                ContentUnavailableView("Select a task", systemImage: "square.grid.3x3", description: Text("Choose a cell above to see its results."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TaskGridView: View {
    let detail: RunDetail
    @Binding var selection: TaskID?

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(TaskID.allCases) { task in
                let files = detail.files(for: task)
                TaskCell(task: task, files: files, isSelected: selection == task)
                    .onTapGesture { selection = files.isEmpty ? nil : task }
                    .help(task.title)
            }
        }
    }
}

struct TaskCell: View {
    let task: TaskID
    let files: [TaskFile]
    let isSelected: Bool

    private var state: (label: String, color: Color, symbol: String) {
        guard !files.isEmpty else { return ("not run", .secondary, "circle.dotted") }
        if files.contains(where: { if case .unreadable = $0.state { return true }; return false }) {
            return ("locked", .orange, "lock.fill")
        }
        if files.contains(where: { if case .corrupt = $0.state { return true }; return false }) {
            return ("corrupt", .red, "exclamationmark.triangle.fill")
        }
        let statuses = files.compactMap { $0.state.envelope?.effectiveStatus }
        if statuses.contains(.failed) { return ("failed", .red, "xmark.octagon.fill") }
        if statuses.contains(.completedWithWarnings) { return ("warnings", .orange, "exclamationmark.triangle.fill") }
        if statuses.contains(.skipped) && statuses.allSatisfy({ $0 == .skipped }) { return ("skipped", .gray, "minus.circle.fill") }
        return ("ok", .green, "checkmark.circle.fill")
    }

    var body: some View {
        let s = state
        VStack(spacing: 4) {
            HStack {
                Text("\(task.rawValue)").font(.caption.weight(.bold))
                Spacer()
                Image(systemName: s.symbol).foregroundStyle(s.color)
            }
            Text(task.title)
                .font(.caption2)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(files.count > 1 ? "\(s.label) · \(files.count) files" : s.label)
                .font(.caption2)
                .foregroundStyle(s.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25)))
        .opacity(files.isEmpty ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

/// All result files of one task (multi-entry tasks have several), each with
/// envelope header, typed view and a raw-JSON toggle.
struct TaskFilesView: View {
    let task: TaskID
    let files: [TaskFile]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(files) { file in
                    TaskFileSection(file: file, showsFileName: files.count > 1)
                }
            }
            .padding(16)
        }
    }
}

struct TaskFileSection: View {
    let file: TaskFile
    let showsFileName: Bool
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(showsFileName ? "\(file.task.title) — \(entryLabel)" : "Task \(file.task.rawValue) — \(file.task.title)")
                        .font(.title3.weight(.semibold))
                    Text(file.ref.fileName).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if file.state.raw != nil {
                    Toggle("Raw JSON", isOn: $showRaw).toggleStyle(.switch).controlSize(.small)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file.ref.url])
                } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }

            switch file.state {
            case .unreadable:
                UnreadableNote(url: file.ref.url)
            case .corrupt(let message):
                Label("This file is not valid JSON: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .rawOnly(let envelope, let raw, let problem):
                if let envelope { EnvelopeHeader(envelope: envelope) }
                if let problem {
                    Label("Could not fully interpret this file (\(problem)). Showing the raw data.", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                RawJSONView(json: raw).frame(minHeight: 200, maxHeight: 600)
            case .decoded(let envelope, let payload, let raw):
                EnvelopeHeader(envelope: envelope)
                if showRaw {
                    RawJSONView(json: raw).frame(minHeight: 200, maxHeight: 600)
                } else {
                    TaskPayloadView(task: file.task, payload: payload)
                }
            }
        }
    }

    private var entryLabel: String {
        if let index = file.ref.deviceIndex { return "device \(index)" }
        return "summary"
    }
}

struct UnreadableNote: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Needs elevation to read", systemImage: "lock.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                RepairPermissionsButton(runDirectory: url.deletingLastPathComponent())
            }
            if model.isHelperReady {
                Text("This file was written with mode 0600 by an older CLI version, so only root can open it. “Repair file permissions” makes this run's result files readable (chmod 644) through the privileged helper.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This file was written with mode 0600 by an older CLI version, so only root can open it. Fix it once from the terminal:")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("sudo chmod 644 \"\(url.path(percentEncoded: false))\"")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                RepairPermissionsHint()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Overview: how many result files are locked, with the repair button.
struct LockedFilesBanner: View {
    @Environment(AppModel.self) private var model
    let runDirectory: URL
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(count == 1 ? "1 result file needs elevation to read" : "\(count) result files need elevation to read", systemImage: "lock.fill")
                    .foregroundStyle(.orange)
                Spacer()
                RepairPermissionsButton(runDirectory: runDirectory)
            }
            if !model.isHelperReady {
                RepairPermissionsHint()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// "Repair file permissions" (helper `repairRunPermissions`, contract 07 §5): chmod 644
/// on the run's `*.json`, then the browser reloads. Renders nothing unless the helper
/// is ready.
struct RepairPermissionsButton: View {
    @Environment(AppModel.self) private var model
    let runDirectory: URL
    @State private var isWorking = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        if model.isHelperReady {
            HStack(spacing: 8) {
                if let result {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(failed ? .red : .secondary)
                        .lineLimit(2)
                }
                if isWorking { ProgressView().controlSize(.small) }
                Button {
                    repair()
                } label: {
                    Label("Repair file permissions", systemImage: "lock.open")
                }
                .disabled(isWorking)
                .help("Make this run's result files readable (chmod 644) through the privileged helper")
            }
        }
    }

    private func repair() {
        isWorking = true
        result = nil
        Task {
            do {
                let changed = try await model.repairPermissions(of: runDirectory)
                result = changed == 1 ? "1 file repaired" : "\(changed) files repaired"
                failed = false
            } catch {
                result = error.localizedDescription
                failed = true
            }
            isWorking = false
        }
    }
}

/// Shown instead of the button while the helper is unavailable.
struct RepairPermissionsHint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Text("With the privileged helper enabled this is one click.")
            Button("Settings → Privileges") { model.selection = .settings }
                .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Report

struct ReportTab: View {
    let summary: RunSummary

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let pdf = summary.reportPDF {
                    Label(pdf.lastPathComponent, systemImage: "doc.richtext").lineLimit(1)
                    Spacer()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([pdf]) }
                    Button("Open in Preview") { NSWorkspace.shared.open(pdf) }
                } else if let txt = summary.reportTXT {
                    Label(txt.lastPathComponent, systemImage: "doc.plaintext").lineLimit(1)
                    Spacer()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([txt]) }
                } else {
                    Label("No report has been built for this run yet", systemImage: "doc")
                    Spacer()
                }
            }
            .padding(12)
            Divider()
            if let pdf = summary.reportPDF {
                PDFKitView(url: pdf)
            } else if let txt = summary.reportTXT, let text = try? String(contentsOf: txt, encoding: .utf8) {
                ScrollView {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                ContentUnavailableView("No report", systemImage: "doc", description: Text("Reports are produced when a run is saved (TXT and PDF)."))
            }
        }
    }
}
