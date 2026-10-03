import SwiftUI
import LSSCore

/// Task 13 — the target and the open TCP ports found by the full-range scan.
struct CustomPortScanDetailView: View {
    let task: TaskID
    let payload: CustomPortScanPayload

    private struct PortRow: Identifiable {
        let id: Int
        let port: Int
        var service: String? { SpecialistPortNames.name(for: port) }
    }

    private var rows: [PortRow] {
        (payload.openPorts ?? []).enumerated().map { PortRow(id: $0.offset, port: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            KeyValueGroup("Target", rows: [
                ("Target IP", Fmt.text(payload.targetIp)),
                ("Hostname", Fmt.text(payload.hostname)),
                ("Open TCP ports", Fmt.int(payload.openPorts?.count)),
            ])

            SectionCard("Open TCP ports", subtitle: "nmap -p- --open across 1–65535") {
                if rows.isEmpty {
                    SpecialistEmptyNote("No open TCP ports found.")
                } else {
                    Table(rows) {
                        TableColumn("Port") { row in
                            Text(String(row.port)).monospacedDigit()
                        }
                        .width(min: 60, ideal: 80, max: 100)
                        TableColumn("Service") { row in
                            Text(row.service ?? "—")
                                .foregroundStyle(row.service == nil ? Color.secondary : Color.primary)
                        }
                    }
                    .specialistTableHeight(rows: rows.count)
                }
            }
        }
    }
}
