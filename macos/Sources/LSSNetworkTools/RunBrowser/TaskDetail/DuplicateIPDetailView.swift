import LSSCore
import SwiftUI

/// Task 12 — Duplicate IP Detection: ARP sweep counts and any IP address that
/// answered from more than one MAC.
struct DuplicateIPDetailView: View {
    let task: TaskID
    let payload: DuplicateIPPayload

    private struct Row: Identifiable {
        let id: Int
        let duplicate: DuplicateIPPayload.Duplicate
    }

    private var rows: [Row] {
        (payload.duplicates ?? []).enumerated().map { Row(id: $0.offset, duplicate: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyValueGroup("ARP sweep", rows: [
                ("Interface", Fmt.text(payload.interface)),
                ("Network range", Fmt.text(payload.network)),
                ("Hosts seen", Fmt.int(payload.totalHostsSeen)),
                ("Duplicate IP addresses", Fmt.int(payload.duplicateCount ?? payload.duplicates?.count)),
            ])

            if payload.hasDuplicates {
                Label("IP conflicts detected", systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if (payload.totalHostsSeen ?? 0) > 0 {
                Label("No IP conflicts detected", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            SectionCard("Duplicate IP addresses", subtitle: "Addresses that answered ARP from more than one MAC") {
                if rows.isEmpty {
                    CoreAuditEmptyNote("No duplicate IP addresses were found.")
                } else {
                    Table(rows) {
                        TableColumn("IP address") { row in
                            Text(Fmt.text(row.duplicate.ip) ?? "—").monospacedDigit()
                        }
                        .width(min: 110, ideal: 130, max: 160)
                        TableColumn("MAC addresses") { row in
                            Text(Fmt.list(row.duplicate.macs) ?? "—")
                        }
                        TableColumn("Vendors") { row in
                            Text(Fmt.list(row.duplicate.vendors?.compactMap(Fmt.text)) ?? "—")
                        }
                    }
                    .coreAuditTableHeight(rows: rows.count)
                }
            }

            if payload.totalHostsSeen == 0 {
                Text("No hosts answered the ARP sweep, so this result may be incomplete (older versions reported this as a success).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
