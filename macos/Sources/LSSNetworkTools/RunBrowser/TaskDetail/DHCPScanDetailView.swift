import LSSCore
import SwiftUI

/// Task 4 — DHCP Network Scan: discovery counts, every responder with its
/// classification, and the raw nmap output behind them.
struct DHCPScanDetailView: View {
    let task: TaskID
    let payload: DHCPScanPayload

    private struct Row: Identifiable {
        let id: Int
        let server: DHCPScanPayload.Server
    }

    private var rows: [Row] {
        (payload.servers ?? []).enumerated().map { Row(id: $0.offset, server: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyValueGroup("Discovery", rows: [
                ("Responders observed", Fmt.int(payload.dhcpRespondersObserved)),
                ("Discovery attempts", Fmt.int(payload.discoveryAttempts)),
                ("Unique offers", Fmt.int(payload.offersObserved)),
                ("Raw offers captured", Fmt.int(payload.rawOffersObserved)),
                ("Relay sources seen", Fmt.list(payload.relaySourcesSeen)),
                ("tcpdump capture used", Fmt.yesNo(payload.tcpdumpCaptureUsed)),
            ])

            HStack(spacing: 12) {
                FlagBadge(label: "Rogue DHCP suspected", value: payload.rogueDhcpSuspected, highlightTrue: true)
                if let rogue = Fmt.list(payload.suspectedRogueServers) {
                    Text(rogue)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            SectionCard("DHCP responders") {
                if rows.isEmpty {
                    CoreAuditEmptyNote("No DHCP responders were observed.")
                } else {
                    Table(rows) {
                        TableColumn("IP address") { row in
                            Text(Fmt.text(row.server.ip) ?? "—").monospacedDigit()
                        }
                        TableColumn("Classification") { row in
                            Text(CoreAuditLabel.humanized(row.server.classification) ?? "—")
                        }
                        TableColumn("Offers") { row in
                            Text(Fmt.int(row.server.offersObserved) ?? "—")
                        }
                        .width(min: 50, ideal: 60, max: 80)
                        TableColumn("Raw offers") { row in
                            Text(Fmt.int(row.server.rawOffersObserved) ?? "—")
                        }
                        .width(min: 70, ideal: 80, max: 100)
                        TableColumn("Open TCP ports") { row in
                            Text(Fmt.ports(row.server.openPorts) ?? "none")
                        }
                        TableColumn("Rogue") { row in
                            FlagBadge(
                                label: row.server.suspectedRogue == true ? "Suspected" : "No",
                                value: row.server.suspectedRogue,
                                highlightTrue: true
                            )
                        }
                        .width(min: 90, ideal: 110, max: 140)
                    }
                    .coreAuditTableHeight(rows: rows.count)
                }
            }

            if let attempts = payload.rawAttempts, !attempts.isEmpty {
                DisclosureGroup("Raw discovery output (\(attempts.count) attempts)") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(attempts.enumerated()), id: \.offset) { index, attempt in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Attempt \(attempt.attempt.map(String.init) ?? String(index + 1))")
                                    .font(.caption.weight(.semibold))
                                Text(attempt.outputExcerpt ?? "")
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }

            CoreAuditNote(text: payload.discoveryNote)
        }
    }
}
