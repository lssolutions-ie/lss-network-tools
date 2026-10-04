import SwiftUI
import LSSCore

/// Task 15 — MAC/vendor discovery, the device-type hint and the nmap service fingerprints.
struct IdentityScanDetailView: View {
    let task: TaskID
    let payload: IdentityScanPayload

    private struct ServiceRow: Identifiable {
        let id: Int
        let service: IdentityScanPayload.Service
    }

    private var rows: [ServiceRow] {
        (payload.services ?? []).enumerated().map { ServiceRow(id: $0.offset, service: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            KeyValueGroup("Target", rows: [
                ("Target IP", Fmt.text(payload.targetIp)),
                ("Hostname", Fmt.text(payload.hostname)),
                ("MAC address", Fmt.text(payload.macAddress)),
                ("Vendor", Fmt.text(payload.vendor)),
                ("Vendor source", Fmt.text(payload.vendorSource)),
                ("Lookup method", Fmt.text(payload.lookupMethod)),
            ])

            if hasIdentity {
                KeyValueGroup("Identity", rows: [
                    ("Host state", Fmt.text(payload.hostState)),
                    ("Device type hint", payload.deviceTypeLabel),
                    ("Confidence", Fmt.text(payload.confidence)?.capitalized),
                    ("Summary", Fmt.text(payload.identitySummary)),
                ])

                HStack(spacing: 20) {
                    FlagBadge(label: "Host responded", value: payload.hostState.map { $0 == "up" })
                    FlagBadge(label: "MAC identified", value: Fmt.text(payload.macAddress) != nil)
                    FlagBadge(label: "Service banners found", value: payload.services.map { !$0.isEmpty })
                }
            } else {
                SpecialistEmptyNote("The identity scan did not complete; only the target is recorded.")
            }

            SectionCard("Services", subtitle: "nmap -Pn -sV --version-light") {
                if rows.isEmpty {
                    SpecialistEmptyNote(payload.services == nil ? "No service scan was recorded." : "No service banners were identified.")
                } else {
                    Table(rows) {
                        TableColumn("Port") { row in
                            Text(row.service.portNumber.map(String.init) ?? Fmt.text(row.service.port) ?? "—")
                                .monospacedDigit()
                        }
                        .width(min: 50, ideal: 70, max: 90)
                        TableColumn("Proto") { row in
                            Text(row.service.transport ?? "—")
                        }
                        .width(min: 40, ideal: 50, max: 60)
                        TableColumn("State") { row in
                            Text(Fmt.text(row.service.state) ?? "—")
                        }
                        .width(min: 50, ideal: 60, max: 80)
                        TableColumn("Service") { row in
                            Text(Fmt.text(row.service.service) ?? "—")
                        }
                        .width(min: 70, ideal: 110, max: 160)
                        TableColumn("Version") { row in
                            Text(Fmt.text(row.service.version) ?? "no version banner")
                                .foregroundStyle(Fmt.text(row.service.version) == nil ? Color.secondary : Color.primary)
                        }
                    }
                    .specialistTableHeight(rows: rows.count)
                }
            }
        }
    }

    /// Failure files carry only `target_ip` and `hostname`.
    private var hasIdentity: Bool {
        payload.hostState != nil || payload.deviceTypeHint != nil || payload.services != nil
    }
}
