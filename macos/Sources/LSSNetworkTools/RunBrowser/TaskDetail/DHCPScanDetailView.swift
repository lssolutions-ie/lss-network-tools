import LSSCore
import SwiftUI

/// Task 4 — DHCP Network Scan: discovery counts, the interface's own lease, every
/// responder with its classification, offered options and rogue reasons, the
/// tcpdump capture summary and the raw nmap output behind them. Every v1.2.252
/// field is optional; a pre-v1.2.252 file renders exactly as before.
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

    /// The file was written by engine v1.2.252 or later (it records how the probe was built).
    private var isV252: Bool {
        payload.probeMacSource != nil || payload.replySourcesSeen != nil || payload.relayAgentsSeen != nil
    }

    private var hasOfferedOptions: Bool {
        rows.contains { row in
            let s = row.server
            return s.offeredRouter != nil || s.offeredSubnetMask != nil || !(s.offeredDns ?? []).isEmpty
                || s.offeredDomain != nil || s.leaseTimeSeconds != nil || s.responderMac != nil
        }
    }

    private var rogueRows: [Row] {
        rows.filter { !($0.server.rogueReasons ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyValueGroup("Discovery", rows: discoveryRows)

            if let lease = payload.systemLease {
                KeyValueGroup("System lease (this interface)", rows: [
                    ("Server", Fmt.text(lease.server)),
                    ("Assigned IP", Fmt.text(lease.assignedIp)),
                    ("Router", Fmt.text(lease.router)),
                    ("DNS", Fmt.list(lease.dns)),
                    ("Domain", Fmt.text(lease.domain)),
                    ("Lease time", Fmt.leaseTime(lease.leaseTimeSeconds)),
                    ("Obtained", leaseObtainedText(lease)),
                    ("Source", Fmt.text(lease.source)),
                ])
            } else if isV252 {
                CoreAuditNote(text: "No DHCP lease is recorded for this interface (static address, or the platform did not report one).")
            }

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
                            .help(row.server.rogueReasonLabels.joined(separator: "\n"))
                        }
                        .width(min: 90, ideal: 110, max: 140)
                    }
                    .coreAuditTableHeight(rows: rows.count)
                }
            }

            if !rogueRows.isEmpty {
                SectionCard("Rogue reasons", subtitle: "Evidence from the offers themselves; open TCP ports are informational only") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(rogueRows) { row in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Fmt.text(row.server.ip) ?? "—").font(.callout.weight(.semibold)).monospacedDigit()
                                    ForEach(row.server.rogueReasonLabels, id: \.self) { reason in
                                        Text(reason).font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            }
                        }
                    }
                }
            }

            if hasOfferedOptions {
                SectionCard("Offered options per responder", subtitle: "First non-empty value seen across the discovery attempts") {
                    Table(rows) {
                        TableColumn("IP address") { row in
                            Text(Fmt.text(row.server.ip) ?? "—").monospacedDigit()
                        }
                        .width(min: 100, ideal: 120, max: 150)
                        TableColumn("Router") { row in
                            Text(Fmt.text(row.server.offeredRouter) ?? "—").monospacedDigit()
                        }
                        TableColumn("Subnet mask") { row in
                            Text(Fmt.text(row.server.offeredSubnetMask) ?? "—").monospacedDigit()
                        }
                        TableColumn("DNS") { row in
                            Text(Fmt.list(row.server.offeredDns) ?? "—").monospacedDigit()
                        }
                        TableColumn("Domain") { row in
                            Text(Fmt.text(row.server.offeredDomain) ?? "—")
                        }
                        TableColumn("Lease") { row in
                            Text(Fmt.leaseTime(row.server.leaseTimeSeconds) ?? "—")
                        }
                        TableColumn("Responder MAC") { row in
                            Text(Fmt.text(row.server.responderMac) ?? "—").monospaced()
                        }
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

    private var discoveryRows: [(label: String, value: String?)] {
        var rows: [(label: String, value: String?)] = [
            ("Responders observed", Fmt.int(payload.dhcpRespondersObserved)),
            ("Discovery attempts", Fmt.int(payload.discoveryAttempts)),
        ]
        if let failed = payload.attemptsFailed, failed > 0 {
            rows.append(("Attempts failed", "\(failed) of \(Fmt.int(payload.discoveryAttempts) ?? "?")"))
        }
        rows.append(("Unique offers", Fmt.int(payload.offersObserved)))
        rows.append(("Raw offers captured", Fmt.int(payload.rawOffersObserved)))
        if isV252 {
            let mac = Fmt.text(payload.probeMac) ?? "nmap default"
            let source = Fmt.text(payload.probeMacSource).map { " (\($0))" } ?? ""
            rows.append(("Probe MAC", mac + source))
        }
        if let offered = payload.dnsServersOffered {
            rows.append(("DNS servers offered", Fmt.list(offered) ?? "none"))
        }
        rows.append(("Reply sources", replySourcesText))
        if let relays = payload.relayAgents {
            rows.append(("Relay agents", Fmt.list(relays) ?? "none"))
        }
        if let passive = payload.passiveServersSeen {
            rows.append(("Passive servers seen", Fmt.list(passive) ?? "none"))
        }
        if let types = payload.captureMessageTypes, !types.isEmpty {
            let order = ["Discover", "Offer", "Request", "ACK", "NAK"]
            let known = order.compactMap { key in types[key].map { "\(key) \($0)" } }
            let others = types.keys.filter { !order.contains($0) }.sorted().map { "\($0) \(types[$0] ?? 0)" }
            rows.append(("Captured message types", (known + others).joined(separator: ", ")))
        }
        rows.append(("tcpdump capture used", Fmt.yesNo(payload.tcpdumpCaptureUsed)))
        return rows
    }

    private var replySourcesText: String? {
        let sources = payload.replySources
        guard !sources.isEmpty else { return isV252 ? "none" : nil }
        return sources.compactMap { source -> String? in
            guard let ip = Fmt.text(source.ip) else { return nil }
            if let mac = Fmt.text(source.mac) { return "\(ip) (\(mac))" }
            return ip
        }
        .joined(separator: ", ")
    }

    private func leaseObtainedText(_ lease: DHCPScanPayload.SystemLease) -> String? {
        guard let text = Fmt.text(lease.obtainedAt) else { return nil }
        if let date = LSSJSON.parseISO8601(text) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return text
    }
}
