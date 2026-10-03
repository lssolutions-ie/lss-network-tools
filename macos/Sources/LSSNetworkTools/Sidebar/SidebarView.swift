import SwiftUI
import LSSCore

enum SidebarItem: Hashable {
    case runAudit
    case task(TaskID)
    case previousRuns
    case settings
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Audit") {
                Label("Run Audit", systemImage: "play.circle")
                    .tag(SidebarItem.runAudit)
            }
            ForEach(TaskGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.tasks) { task in
                        Label {
                            Text("\(task.rawValue). \(task.title)")
                        } icon: {
                            Image(systemName: task.symbolName)
                        }
                        .tag(SidebarItem.task(task))
                    }
                }
            }
            Section("Results") {
                Label("Previous Runs", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.previousRuns)
            }
            Section {
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
    }
}
