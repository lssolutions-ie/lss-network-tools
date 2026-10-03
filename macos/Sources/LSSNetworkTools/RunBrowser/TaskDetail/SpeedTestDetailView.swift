import LSSCore
import SwiftUI

/// Task 2 — Internet Speed Test: headline download / upload / ping tiles and
/// the connection the measurement was taken from.
struct SpeedTestDetailView: View {
    let task: TaskID
    let payload: SpeedTestPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let server = payload.server {
                HStack(spacing: 12) {
                    SpeedStatTile(label: "Download", value: Fmt.mbps(server.downloadMbps))
                    SpeedStatTile(label: "Upload", value: Fmt.mbps(server.uploadMbps))
                    SpeedStatTile(label: "Ping", value: Fmt.ms(server.pingMs))
                }
                KeyValueGroup("Connection", rows: [
                    ("Public IP", Fmt.text(server.publicIp)),
                    ("ISP", Fmt.text(server.ispName)),
                    ("Test server", Fmt.text(server.testServer)),
                    ("Location", Fmt.text(server.location)),
                    ("Timestamp", Fmt.text(server.timestamp)),
                    ("Measurements recorded", Fmt.int(payload.speedTestsFound)),
                ])
            } else {
                CoreAuditEmptyNote("No speed test measurement was recorded.")
            }
            CoreAuditNote(text: payload.methodology)
        }
    }
}

/// One headline number; a dash when the measurement is missing.
private struct SpeedStatTile: View {
    let label: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
