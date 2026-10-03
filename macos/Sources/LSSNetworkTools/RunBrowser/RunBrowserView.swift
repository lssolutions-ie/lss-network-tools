import SwiftUI
import LSSCore

/// Previous Runs: list on the left, selected run on the right.
struct RunBrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var browser = model.runBrowser
        HSplitView {
            RunListView()
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            Group {
                if let detail = browser.detail {
                    RunDetailView(detail: detail)
                } else if browser.selectedRunID != nil {
                    ProgressView("Loading run…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Select a run",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(model.cli == nil
                            ? "The command-line tool is not installed, so there is nowhere to read runs from."
                            : "Runs are read from \(model.cli?.outputDirectory.path(percentEncoded: false) ?? "")")
                    )
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.configureRunBrowser() }
    }
}

struct RunListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var browser = model.runBrowser
        VStack(spacing: 0) {
            List(browser.runs, selection: $browser.selectedRunID) { run in
                RunRow(run: run).tag(run.id)
            }
            .listStyle(.inset)
            .overlay {
                if browser.runs.isEmpty && !browser.isLoading {
                    ContentUnavailableView("No runs yet", systemImage: "tray", description: Text("Completed audits appear here."))
                }
            }
            Divider()
            HStack {
                Text("\(browser.runs.count) run\(browser.runs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if browser.isLoading { ProgressView().controlSize(.small) }
                Button {
                    Task { await browser.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Rescan the output directory")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

struct RunRow: View {
    let run: RunSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.client ?? run.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let date = run.generatedAt {
                    Text(date, format: .dateTime.day().month(.abbreviated).year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let text = run.generatedAtText {
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let location = run.location {
                Text(location).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                if let note = run.note, !note.isEmpty {
                    Label(note, systemImage: "note.text").lineLimit(1)
                }
                Label("\(run.presentTasks.count) task\(run.presentTasks.count == 1 ? "" : "s")", systemImage: "checklist")
                if run.reportPDF != nil {
                    Label("PDF", systemImage: "doc.richtext")
                }
                if run.unreadableCount > 0 {
                    Label("\(run.unreadableCount) locked", systemImage: "lock")
                        .foregroundStyle(.orange)
                }
                if !run.hasManifest {
                    Label("no manifest", systemImage: "questionmark.folder")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
