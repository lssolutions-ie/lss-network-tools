import SwiftUI
import LSSCore

/// Explicit confirmation before a run that includes Task 10, Task 14 or the
/// full audit (which contains Task 10). "I understand, run it" is the only
/// path that sets `--yes`; Cancel returns to the sheet unchanged.
struct StressConsentDialog: View {
    let tasks: [TaskID]
    let isFullAudit: Bool
    let targetIP: String
    let onDecision: (Bool) -> Void

    private var stressTasks: [TaskID] {
        isFullAudit ? [.gatewayStress] : tasks.filter(\.isStressTest)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run stress tests on this network?")
                        .font(.title3.weight(.semibold))
                    Text(isFullAudit
                         ? "The full audit includes Task 10, a gateway stress test."
                         : "Your selection includes \(stressTasks.count == 1 ? "a stress test" : "stress tests").")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(stressTasks) { task in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: task.symbolName)
                            .foregroundStyle(.orange)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Task \(task.rawValue) — \(task.title)")
                                .font(.headline)
                            Text(detail(for: task))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            Text("These stages send sustained ICMP floods — baseline, jitter, large packets, ramping sizes, a sustained flood and recovery. They can saturate the link, raise latency for every user and trip intrusion detection. Run them only in a maintenance window or with the client's agreement. Confirming passes --yes to the command-line tool.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { onDecision(false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("I understand, run it", role: .destructive) { onDecision(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func detail(for task: TaskID) -> String {
        switch task {
        case .gatewayStress:
            "Floods the default gateway of the selected interface with ICMP for several minutes and measures loss, latency and recovery."
        case .customStress:
            targetIP.isEmpty
                ? "Floods the target IP you entered with ICMP for several minutes and measures loss, latency and recovery."
                : "Floods \(targetIP) with ICMP for several minutes and measures loss, latency and recovery."
        default:
            task.summary
        }
    }
}
