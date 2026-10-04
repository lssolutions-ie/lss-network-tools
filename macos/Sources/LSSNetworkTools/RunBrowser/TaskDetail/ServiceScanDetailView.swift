import LSSCore
import SwiftUI

/// Tasks 6–9 — DNS / LDAP-AD / SMB-NFS / Printer network scans: the hosts
/// that answered on the scanned ports. Task 6 adds the candidate sources,
/// transport, resolution test and PTR columns (v1.2.252 fields are optional and
/// show a dash in older files), Task 8 the SMB signing column. (Conditional
/// columns inside one `Table` need macOS 14.4, so the three variants share a
/// `Group` of columns.)
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
            KeyValueGroup("Scan", rows: scanRows)

            SectionCard(sectionTitle, subtitle: sectionSubtitle) {
                if rows.isEmpty {
                    CoreAuditEmptyNote(emptyText)
                } else {
                    // DNS rows carry a two-line resolution cell, so budget two row heights each.
                    hostTable
                        .coreAuditTableHeight(rows: task == .dnsScan ? rows.count * 2 : rows.count)
                }
            }
        }
    }

    private var scanRows: [(label: String, value: String?)] {
        var rows: [(label: String, value: String?)] = [
            ("Network range", Fmt.text(payload.network)),
            ("Ports scanned", Fmt.text(payload.scanPorts)),
        ]
        if let range = Fmt.text(payload.scannedRange) {
            rows.append(("Range swept", payload.rangeTruncated == true ? "\(range) (capped; the interface network is larger)" : range))
        }
        rows.append(("Hosts found", Fmt.int(payload.servers?.count)))
        return rows
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
                TableColumn("Found via") { row in
                    SourcesCell(server: row.server)
                }
                .width(min: 120, ideal: 170, max: 260)
                TableColumn("Port 53") { row in
                    Text(transportText(row.server) ?? "—")
                        .foregroundStyle(transportText(row.server) == nil ? .secondary : .primary)
                }
                .width(min: 90, ideal: 130, max: 180)
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

    private func transportText(_ server: ServiceScanPayload.Server) -> String? {
        guard let transport = server.transport else { return nil }
        let tcp = Fmt.text(transport.tcp) ?? "unknown"
        let udp = Fmt.text(transport.udp) ?? "unknown"
        return "TCP \(tcp) · UDP \(udp)"
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

    private var sectionSubtitle: String? {
        guard task == .dnsScan, (payload.servers ?? []).contains(where: { $0.sources != nil }) else { return nil }
        return "Candidates come from the subnet sweep, the configured resolvers and the DHCP offers / system lease; each one was tested"
    }

    private var emptyText: String {
        task == .dnsScan
            ? "No DNS server was found on the network range, in the configured resolvers or in the DHCP offers."
            : "No matching hosts were found on the network range."
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

/// Task 6 (v1.2.252): where the candidate came from, as tags, plus an
/// "outside subnet" marker for configured or offered resolvers on another network.
private struct SourcesCell: View {
    let server: ServiceScanPayload.Server

    var body: some View {
        if server.sources == nil, server.onSubnet == nil {
            Text("—").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                ForEach(server.sourceLabels, id: \.self) { label in
                    TagView(text: label)
                }
                if server.onSubnet == false {
                    Label("outside subnet", systemImage: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Task 6: result of resolving an external name through the server, the
/// recursion state (tri-state since v1.2.252), the private-answer flag and the
/// internal-domain test.
private struct ResolutionCell: View {
    let test: ServiceScanPayload.ResolutionTest?

    var body: some View {
        if let test {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(summary(test))
                    recursionLabel(test.recursionState)
                    if test.answeredWithPrivateAddress == true {
                        Label("Private answer (filtering or rebinding)", systemImage: "exclamationmark.octagon.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .help("The external name resolved to a private address — DNS filtering or a rebinding risk")
                    }
                }
                if let internalTest = test.internalTest, let domain = Fmt.text(internalTest.domain) {
                    Text(internalSummary(internalTest, domain: domain))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Not tested").foregroundStyle(.secondary)
        }
    }

    private func summary(_ test: ServiceScanPayload.ResolutionTest) -> String {
        let domain = Fmt.text(test.domain) ?? "google.com"
        guard test.resolved == true else {
            var text = "Did not resolve \(domain)"
            if let rcode = Fmt.text(test.rcode) { text += " (\(rcode))" }
            if let attempts = test.attempts, attempts > 1 { text += ", \(attempts) attempts" }
            return text
        }
        var text = "Resolved \(domain)"
        if let ms = Fmt.ms(test.responseMs) { text += " in \(ms)" }
        if let count = test.resolvedIps?.count, count > 0 {
            text += " (\(count) address\(count == 1 ? "" : "es"))"
        }
        if let attempts = test.attempts, attempts > 1 { text += ", \(attempts) attempts" }
        return text
    }

    @ViewBuilder
    private func recursionLabel(_ state: ServiceScanPayload.Recursion) -> some View {
        switch state {
        case .enabled:
            Label("Recursion enabled", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Answers recursive queries from LAN clients")
        case .disabled:
            Label("Recursion disabled", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unknown:
            Label("Recursion unknown", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("No reply carried the Recursion Available bit (timeout)")
        }
    }

    private func internalSummary(_ internalTest: ServiceScanPayload.ResolutionTest.InternalTest, domain: String) -> String {
        var text: String
        switch internalTest.resolved {
        case .some(true): text = "Internal domain \(domain): resolved"
        case .some(false): text = "Internal domain \(domain): not resolved"
        case .none: text = "Internal domain \(domain): not tested"
        }
        switch internalTest.srvFound {
        case .some(true): text += ", AD SRV record found"
        case .some(false): text += ", no AD SRV record"
        case .none: break
        }
        return text
    }
}
