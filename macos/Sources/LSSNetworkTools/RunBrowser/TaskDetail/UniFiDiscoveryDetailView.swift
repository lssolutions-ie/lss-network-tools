import SwiftUI
import LSSCore

/// Task 18 — confirmed and probable UniFi devices, plus the non-Ubiquiti hosts
/// that answered the UDP 10001 / LLDP probes.
struct UniFiDiscoveryDetailView: View {
    let task: TaskID
    let payload: UniFiDiscoveryPayload

    private struct DeviceRow: Identifiable {
        let id: Int
        let device: UniFiDiscoveryPayload.Device

        var ipKey: UInt32 { SpecialistSort.ipv4Key(device.ip) }
        var mac: String { Fmt.text(device.mac) ?? "" }
        var model: String { Fmt.text(device.model) ?? "" }
        var confidence: String { device.isProbable ? "Probable (SSH banner only)" : "Confirmed" }
    }

    @State private var sortOrder = [KeyPathComparator(\DeviceRow.ipKey)]

    private var deviceRows: [DeviceRow] {
        (payload.devices ?? []).enumerated()
            .map { DeviceRow(id: $0.offset, device: $0.element) }
            .sorted(using: sortOrder)
    }

    private var falsePositiveRows: [DeviceRow] {
        (payload.falsePositives ?? []).enumerated()
            .map { DeviceRow(id: $0.offset, device: $0.element) }
            .sorted { $0.ipKey < $1.ipKey }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            KeyValueGroup("Scan", rows: [
                ("Interface", Fmt.text(payload.interface)),
                ("Subnet", Fmt.text(payload.subnet)),
                ("Broadcast", Fmt.text(payload.broadcast)),
                ("Devices found", Fmt.int(payload.devicesFound)),
                ("Confirmed", Fmt.int(payload.devices == nil ? nil : payload.confirmedDevices.count)),
                ("Probable", Fmt.int(payload.devices == nil ? nil : payload.probableDevices.count)),
                ("Possible false positives", Fmt.int(payload.falsePositives?.count)),
            ])

            SectionCard("UniFi devices", subtitle: "Confirmed by UDP 10001 TLV, Ubiquiti OUI or LLDP; probable = Dropbear SSH banner only, never adopted by Task 19") {
                if deviceRows.isEmpty {
                    SpecialistEmptyNote("No UniFi devices found.")
                } else {
                    Table(deviceRows, sortOrder: $sortOrder) {
                        TableColumn("IP address", value: \.ipKey) { row in
                            Text(Fmt.text(row.device.ip) ?? "—").monospacedDigit()
                        }
                        .width(min: 110, ideal: 130, max: 160)
                        TableColumn("MAC address", value: \.mac) { row in
                            Text(row.mac.isEmpty ? "unknown" : row.mac)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(row.mac.isEmpty ? Color.secondary : Color.primary)
                        }
                        .width(min: 150, ideal: 160, max: 190)
                        TableColumn("Model", value: \.model) { row in
                            Text(row.model.isEmpty ? "—" : row.model)
                        }
                        TableColumn("Confidence", value: \.confidence) { row in
                            Label(row.confidence, systemImage: row.device.isProbable ? "questionmark.circle" : "checkmark.seal")
                                .foregroundStyle(row.device.isProbable ? Color.orange : Color.primary)
                        }
                        .width(min: 120, ideal: 200, max: 240)
                    }
                    .specialistTableHeight(rows: deviceRows.count)
                }
            }

            SectionCard("Possible false positives", subtitle: "Answered UDP 10001 or LLDP but carry a non-Ubiquiti MAC") {
                if falsePositiveRows.isEmpty {
                    SpecialistEmptyNote(payload.falsePositives == nil ? "Not recorded in this file." : "None.")
                } else {
                    Table(falsePositiveRows) {
                        TableColumn("IP address") { row in
                            Text(Fmt.text(row.device.ip) ?? "—").monospacedDigit()
                        }
                        .width(min: 110, ideal: 130, max: 160)
                        TableColumn("MAC address") { row in
                            Text(row.mac.isEmpty ? "unknown" : row.mac)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(row.mac.isEmpty ? Color.secondary : Color.primary)
                        }
                    }
                    .specialistTableHeight(rows: falsePositiveRows.count)
                }
            }
        }
    }
}
