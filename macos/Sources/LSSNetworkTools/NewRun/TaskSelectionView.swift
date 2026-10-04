import SwiftUI
import LSSCore

/// "Full audit (1–12)" / "Selected tasks" with grouped checkboxes. The grid
/// starts collapsed behind a one-line summary when the sheet was opened with a
/// task preselected (task screens), and expanded when the user picks
/// "Selected tasks" themselves. Tasks that already have results in a continued
/// run show a grey tick and start unchecked.
struct TaskSelectionView: View {
    @Binding var draft: RunDraft
    let existingTasks: Set<TaskID>
    @State private var isExpanded: Bool

    init(draft: Binding<RunDraft>, existingTasks: Set<TaskID>, expanded: Bool) {
        _draft = draft
        self.existingTasks = existingTasks
        _isExpanded = State(initialValue: expanded)
    }

    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]

    var body: some View {
        Picker("Tasks", selection: $draft.selectionMode) {
            ForEach(RunDraft.SelectionMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: draft.selectionMode) { _, mode in
            // Choosing "Selected tasks" by hand means the user wants the list.
            if mode == .selected && draft.selectedTasks.isEmpty { isExpanded = true }
        }

        switch draft.selectionMode {
        case .fullAudit:
            VStack(alignment: .leading, spacing: 4) {
                Text("Tasks 1–12 run in order, exactly like option 000 in the CLI menu. Task 10 (Gateway Stress Test) needs your confirmation before the run starts.")
                if draft.isContinuing && !existingTasks.isEmpty {
                    Text("Tasks already in this run are run again; single-file tasks replace their result, Task 10 adds a new file.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        case .selected:
            summaryRow
            if isExpanded {
                taskGrid
            }
        }
    }

    /// One line naming the selection, with the expand/collapse control.
    private var summaryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: draft.selectedTasks.isEmpty ? "circle.dashed" : "checklist")
                .foregroundStyle(draft.selectedTasks.isEmpty ? .orange : .secondary)
            Text(selectionSummary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(isExpanded ? "Hide list" : "Change…") {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }
            .controlSize(.small)
        }
    }

    private var selectionSummary: String {
        let tasks = draft.selectedTasks.sorted()
        switch tasks.count {
        case 0: return "No tasks selected"
        case 1: return "Task \(tasks[0].rawValue) — \(tasks[0].title)"
        case 2...4: return tasks.map { "\($0.rawValue). \($0.title)" }.joined(separator: " · ")
        default: return "\(tasks.count) tasks: " + tasks.map { String($0.rawValue) }.joined(separator: ", ")
        }
    }

    private var taskGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(TaskGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                        ForEach(group.tasks) { task in
                            taskToggle(task)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Select core audit") { draft.selectedTasks = Set(TaskID.auditTasks) }
                Button("Clear") { draft.selectedTasks = [] }
                    .disabled(draft.selectedTasks.isEmpty)
                Spacer()
                if !existingTasks.isEmpty {
                    Label("Grey ticks: already in this run", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            .font(.caption)
        }
        .padding(.top, 4)
    }

    private func taskToggle(_ task: TaskID) -> some View {
        let alreadyPresent = existingTasks.contains(task)
        return Toggle(isOn: isOn(task)) {
            HStack(spacing: 6) {
                Image(systemName: task.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("\(task.rawValue). \(task.title)")
                    .lineLimit(1)
                if task.isStressTest {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Stress test — needs confirmation")
                }
                if alreadyPresent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .help("Already has results in this run")
                }
            }
            .font(.callout)
        }
        .toggleStyle(.checkbox)
        .help(task.summary)
    }

    private func isOn(_ task: TaskID) -> Binding<Bool> {
        Binding(
            get: { draft.selectedTasks.contains(task) },
            set: { on in
                if on { draft.selectedTasks.insert(task) } else { draft.selectedTasks.remove(task) }
            }
        )
    }
}
