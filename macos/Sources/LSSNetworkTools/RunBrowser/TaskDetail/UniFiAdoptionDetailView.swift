import SwiftUI
import LSSCore

/// Task 19 — controller and inform URL, adoption counts and the per-device result.
struct UniFiAdoptionDetailView: View {
    let task: TaskID
    let payload: UniFiAdoptionPayload

    private struct ResultRow: Identifiable {
        let id: Int
        let device: UniFiAdoptionPayload.Device
    }

    private var rows: [ResultRow] {
        (payload.devices ?? []).enumerated().map { ResultRow(id: $0.offset, device: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            KeyValueGroup("Controller", rows: [
                ("Controller", Fmt.text(payload.controller)),
                ("Inform URL", Fmt.text(payload.informUrl)),
                ("Interface", Fmt.text(payload.interface)),
            ])

            KeyValueGroup("Adoption", rows: [
                ("Devices attempted", Fmt.int(payload.devicesFound)),
                ("set-inform sent", Fmt.int(payload.devicesAdopted)),
                ("Failed", Fmt.int(failedCount)),
            ])

            if let found = payload.devicesFound, found > 0, payload.devicesAdopted == 0 {
                Label("set-inform could not be sent to any device; the file still reports status success.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SectionCard("Devices", subtitle: "mca-cli-op set-inform over SSH; probable devices from Task 18 are skipped") {
                if rows.isEmpty {
                    SpecialistEmptyNote("No adoption attempts were recorded.")
                } else {
                    Table(rows) {
                        TableColumn("IP address") { row in
                            Text(Fmt.text(row.device.ip) ?? "—").monospacedDigit()
                        }
                        .width(min: 110, ideal: 130, max: 160)
                        TableColumn("Result") { row in
                            Label(row.device.isAdopted ? "Adopted" : "Failed",
                                  systemImage: row.device.isAdopted ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(row.device.isAdopted ? Color.green : Color.red)
                        }
                        .width(min: 90, ideal: 110, max: 140)
                        TableColumn("Detail") { row in
                            Text(row.device.isAdopted ? "set-inform sent" : (row.device.failureReason ?? "—"))
                        }
                    }
                    .specialistTableHeight(rows: rows.count)
                }
            }
        }
    }

    /// Failed rows when the list is present, otherwise derived from the counts.
    private var failedCount: Int? {
        if payload.devices != nil { return payload.failedDevices.count }
        guard let found = payload.devicesFound, let adopted = payload.devicesAdopted else { return nil }
        return max(0, found - adopted)
    }
}
