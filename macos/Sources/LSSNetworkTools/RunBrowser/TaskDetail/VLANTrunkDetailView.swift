import LSSCore
import SwiftUI

/// Task 11 — VLAN / Trunk Detection: 802.1Q tags seen on the port, CDP and
/// LLDP neighbours, and the trunk indicators.
struct VLANTrunkDetailView: View {
    let task: TaskID
    let payload: VLANTrunkPayload

    private struct CDPRow: Identifiable {
        let id: Int
        let neighbour: VLANTrunkPayload.CDPNeighbour
    }

    private struct LLDPRow: Identifiable {
        let id: Int
        let neighbour: VLANTrunkPayload.LLDPNeighbour
    }

    private var vlanIDs: [Int] { payload.observedVlanIds ?? [] }

    private var cdpRows: [CDPRow] {
        (payload.cdpNeighbours ?? []).enumerated().map { CDPRow(id: $0.offset, neighbour: $0.element) }
    }

    private var lldpRows: [LLDPRow] {
        (payload.lldpNeighbours ?? []).enumerated().map { LLDPRow(id: $0.offset, neighbour: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyValueGroup("Capture", rows: [
                ("Interface", Fmt.text(payload.interface)),
                ("802.1Q tagged frames observed", Fmt.yesNo(payload.taggedFramesObserved)),
                ("VLAN IDs observed", Fmt.int(vlanIDs.isEmpty ? nil : vlanIDs.count)),
                ("Double-tag probe", doubleTagText),
            ])

            if let indicators = payload.indicators {
                HStack(spacing: 16) {
                    FlagBadge(label: "Trunk port suspected", value: indicators.trunkPortSuspected, highlightTrue: true)
                    FlagBadge(label: "CDP/LLDP exposed", value: indicators.cdpExposed, highlightTrue: true)
                    FlagBadge(label: "Multiple VLANs visible", value: indicators.multipleVlansVisible, highlightTrue: true)
                }
            }

            SectionCard("Observed VLAN IDs") {
                if vlanIDs.isEmpty {
                    CoreAuditEmptyNote("No 802.1Q tagged frames were observed.")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(vlanIDs, id: \.self) { id in
                                Text("VLAN \(id)")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                }
            }

            SectionCard("CDP neighbours") {
                if cdpRows.isEmpty {
                    CoreAuditEmptyNote("No CDP neighbour frames were received.")
                } else {
                    Table(cdpRows) {
                        TableColumn("Device ID") { row in
                            Text(Fmt.text(row.neighbour.deviceId) ?? "—")
                        }
                        TableColumn("Platform") { row in
                            Text(Fmt.text(row.neighbour.platform) ?? "—")
                        }
                        TableColumn("Port") { row in
                            Text(Fmt.text(row.neighbour.portId) ?? "—")
                        }
                        TableColumn("Native VLAN") { row in
                            Text(Fmt.int(row.neighbour.nativeVlan) ?? "—")
                        }
                        .width(min: 80, ideal: 90, max: 110)
                        TableColumn("VTP domain") { row in
                            Text(Fmt.text(row.neighbour.vtpDomain) ?? "—")
                        }
                        TableColumn("Duplex") { row in
                            Text(CoreAuditLabel.humanized(row.neighbour.duplex) ?? "—")
                        }
                        .width(min: 60, ideal: 70, max: 90)
                    }
                    .coreAuditTableHeight(rows: cdpRows.count)
                }
            }

            SectionCard("LLDP neighbours") {
                if lldpRows.isEmpty {
                    CoreAuditEmptyNote("No LLDP neighbour frames were received.")
                } else {
                    Table(lldpRows) {
                        TableColumn("System name") { row in
                            Text(Fmt.text(row.neighbour.systemName) ?? "—")
                        }
                        TableColumn("Chassis ID") { row in
                            Text(Fmt.text(row.neighbour.chassisId) ?? "—")
                        }
                        TableColumn("Port ID") { row in
                            Text(Fmt.text(row.neighbour.portId) ?? "—")
                        }
                        TableColumn("Description") { row in
                            Text(Fmt.text(row.neighbour.systemDescription) ?? "—")
                        }
                    }
                    .coreAuditTableHeight(rows: lldpRows.count)
                }
            }
        }
    }

    private var doubleTagText: String? {
        guard let probe = payload.doubleTagProbe else { return nil }
        guard probe.attempted == true else { return "Not attempted" }
        switch probe.vulnerable {
        case .some(true): return "Vulnerable"
        case .some(false): return "Not vulnerable"
        case .none: return "Inconclusive"
        }
    }
}
