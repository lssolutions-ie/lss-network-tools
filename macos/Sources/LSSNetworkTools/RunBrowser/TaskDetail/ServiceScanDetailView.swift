import LSSCore
import SwiftUI

/// Tasks 6–9 — DNS / LDAP-AD / SMB-NFS / Printer network scans: the hosts
/// that answered on the scanned ports. Task 6 adds the resolution test and PTR
/// columns, Task 8 the SMB signing column. (Conditional columns inside one
/// `Table` need macOS 14.4, so the three variants share a `Group` of columns.)
struct ServiceScanDetailView: View {
    let task: TaskID
    let payload: ServiceScanPayload

    private struct Row: Identifiable {
        let id: Int
        let server: ServiceScanPayload.Server

        var ipKey: UInt32 { CoreAuditSort.ipv4Key(server.ip) }
        var portCount: Int { server.openPorts?.count ?? 0 }
    }

    @State private var sortOrder = [KeyPathComparator(\Row.ipKey)]

    private var rows: [Row] {
        (payload.servers ?? [])
            .enumerated()
            .map { Row(id: $0.offset, server: $0.element) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyValueGroup("Scan", rows: [
                ("Network range", Fmt.text(payload.network)),
                ("Ports scanned", Fmt.text(payload.scanPorts)),
                ("Hosts found", Fmt.int(payload.servers?.count)),
            ])

            SectionCard(sectionTitle) {
                if rows.isEmpty {
                    CoreAuditEmptyNote("No matching hosts were found on the network range.")
                } else {
                    hostTable
                        .coreAuditTableHeight(rows: rows.count)
                }
            }
        }
    }

    @ViewBuilder
    private var hostTable: some View {
        switch task {
        case .smbNfsScan:
            Table(rows, sortOrder: $sortOrder) {
                baseColumns
                TableColumn("SMB signing") { row in
                    SMBSigningCell(server: row.server)
                }
                .width(min: 110, ideal: 130, max: 170)
            }
        case .dnsScan:
            Table(rows, sortOrder: $sortOrder) {
                baseColumns
                TableColumn("Resolution test") { row in
                    ResolutionCell(test: row.server.resolutionTest)
                }
                TableColumn("PTR") { row in
                    Text(Fmt.text(row.server.ptrHostname) ?? "—")
                }
            }
        default:
            Table(rows, sortOrder: $sortOrder) {
                baseColumns
            }
        }
    }

    /// IP (sortable), open ports (sortable by count) and service labels.
    private var baseColumns: some TableColumnContent<Row, KeyPathComparator<Row>> {
        Group {
            TableColumn("IP address", value: \Row.ipKey) { row in
                Text(Fmt.text(row.server.ip) ?? "—").monospacedDigit()
            }
            .width(min: 110, ideal: 130, max: 160)
            TableColumn("Open ports", value: \Row.portCount) { row in
                Text(Fmt.ports(row.server.openPorts) ?? "—")
            }
            TableColumn("Services") { row in
                Text(Fmt.list(row.server.detectedServices) ?? "—")
            }
        }
    }

    private var sectionTitle: String {
        switch task {
        case .dnsScan: "DNS servers"
        case .ldapScan: "LDAP / Active Directory hosts"
        case .smbNfsScan: "SMB / NFS hosts"
        case .printServerScan: "Printers and print servers"
        default: "Hosts"
        }
    }
}

/// Task 8: whether SMB signing is enforced. A host that did not answer the
/// `smb2-security-mode` probe shows "Not checked"; one without port 445 a dash.
private struct SMBSigningCell: View {
    let server: ServiceScanPayload.Server

    var body: some View {
        switch server.smbSigningRequired {
        case .some(true):
            FlagBadge(label: "Required", value: true)
        case .some(false):
            FlagBadge(label: "Not required", value: true, highlightTrue: true)
        case .none:
            Text(server.openPorts?.contains(445) == true ? "Not checked" : "—")
                .foregroundStyle(.secondary)
        }
    }
}

/// Task 6: result of resolving `google.com` through the server plus the two
/// security flags (open resolver, DNS rebinding risk).
private struct ResolutionCell: View {
    let test: ServiceScanPayload.ResolutionTest?

    var body: some View {
        if let test {
            HStack(spacing: 8) {
                Text(summary(test))
                if test.openResolver == true {
                    Label("Open resolver", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if test.rebindingRisk == true {
                    Label("Rebinding risk", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func summary(_ test: ServiceScanPayload.ResolutionTest) -> String {
        let domain = Fmt.text(test.domain) ?? "google.com"
        guard test.resolved == true else { return "Did not resolve \(domain)" }
        var text = "Resolved \(domain)"
        if let ms = Fmt.ms(test.responseMs) { text += " in \(ms)" }
        if let count = test.resolvedIps?.count, count > 0 {
            text += " (\(count) address\(count == 1 ? "" : "es"))"
        }
        return text
    }
}
