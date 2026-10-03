import SwiftUI
import LSSCore

/// Task 20 — the MAC that was looked up and the IP (if any) seen using it.
struct FindByMACDetailView: View {
    let task: TaskID
    let payload: FindByMACPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: payload.isFound ? "checkmark.circle.fill" : "questionmark.circle")
                    .font(.title2)
                    .foregroundStyle(payload.isFound ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(payload.isFound ? "Device found" : "No IP found for this MAC")
                        .font(.headline)
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            KeyValueGroup("Lookup", rows: [
                ("MAC queried", Fmt.text(payload.macQueried)),
                ("IP found", Fmt.text(payload.ipFound)),
                ("Interface", Fmt.text(payload.interface)),
                ("Subnet", Fmt.text(payload.subnet)),
            ])
        }
    }

    private var detail: String {
        if payload.isFound {
            return "\(Fmt.text(payload.macQueried) ?? "The MAC") answered ARP from \(payload.ipFound ?? "—") during the scan."
        }
        if let subnet = Fmt.text(payload.subnet) {
            return "No host with this MAC answered ARP on \(subnet) across five nmap -sn passes. If the task failed (see the status above) the subnet was not actually scanned; otherwise the device may be offline or on another VLAN."
        }
        return "The subnet of the selected interface could not be determined, so nothing was scanned."
    }
}
