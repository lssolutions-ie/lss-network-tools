import Charts
import LSSCore
import SwiftUI

/// Task 5 — DHCP Response Time: Discover→Offer latency per probe (lost probes
/// marked), summary statistics, indicators, the responders seen (v1.2.252), the
/// options they offered, the probe method and the subnet utilisation estimate.
struct DHCPResponseTimeDetailView: View {
    let task: TaskID
    let payload: DHCPResponseTimePayload

    private var probes: [DHCPResponseTimePayload.ProbeSample] { payload.probes }
    private var responded: [DHCPResponseTimePayload.ProbeSample] { probes.filter { !$0.isLost } }
    private var lost: [DHCPResponseTimePayload.ProbeSample] { probes.filter(\.isLost) }
    private var serversSeen: [DHCPResponseTimePayload.ServerSeen] { payload.serversSeenRows }

    /// Keeps the chart readable when every probe was lost (no bars to scale to).
    private var yUpperBound: Double {
        let peak = responded.compactMap(\.responseMs).max() ?? 0
        return max(peak * 1.15, 1)
    }

    private var hasOfferedOptions: Bool {
        payload.offeredRouter != nil || !(payload.offeredDns ?? []).isEmpty
            || payload.offeredDomain != nil || payload.leaseTimeSeconds != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyValueGroup("Summary", rows: summaryRows)

            SectionCard("Discover → Offer time per probe", subtitle: lost.isEmpty ? nil : "A cross at the baseline marks a probe that received no Offer") {
                if probes.isEmpty {
                    CoreAuditEmptyNote("No probes were recorded.")
                } else {
                    probeChart
                }
            }

            if let indicators = payload.indicators {
                HStack(spacing: 16) {
                    FlagBadge(label: "Slow response", value: indicators.slowResponse, highlightTrue: true)
                    FlagBadge(label: "High packet loss", value: indicators.highLoss, highlightTrue: true)
                    if indicators.highUtilization != nil {
                        FlagBadge(label: "High subnet utilisation", value: indicators.highUtilization, highlightTrue: true)
                    }
                    if indicators.probeInconsistent != nil {
                        FlagBadge(label: "Probe inconsistent with discovery", value: indicators.probeInconsistent, highlightTrue: true)
                            .help("Task 4 observed DHCP offers on this interface a moment ago but this probe received none — a probe or receive-path problem, not a DHCP outage")
                    }
                    if indicators.serverMismatch != nil {
                        FlagBadge(label: "Responder mismatch with discovery", value: indicators.serverMismatch, highlightTrue: true)
                            .help("A server answered the probe that discovery (Task 4) did not see — possible second DHCP server")
                    }
                    if payload.multipleResponders != nil {
                        FlagBadge(label: "Multiple responders", value: payload.multipleResponders, highlightTrue: true)
                    }
                }
            }

            if payload.indicators?.probeInconsistent == true {
                CoreAuditNote(text: "Discovery (Task 4) saw DHCP offers on this interface but the response-time probe received none: treat this as a probe or receive-path problem, not a DHCP outage.")
            }

            if !serversSeen.isEmpty {
                SectionCard("Responders seen", subtitle: respondersSubtitle) {
                    Table(serversSeen) {
                        TableColumn("Server") { server in
                            HStack(spacing: 6) {
                                Text(server.ip).monospacedDigit()
                                if payload.unexpectedServers?.contains(server.ip) == true {
                                    Label("not seen by discovery", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        TableColumn("Offers") { server in
                            Text(Fmt.int(server.stats.offers) ?? "—")
                        }
                        .width(min: 50, ideal: 60, max: 80)
                        TableColumn("Min") { server in
                            Text(Fmt.ms(server.stats.minMs) ?? "—")
                        }
                        .width(min: 60, ideal: 80, max: 110)
                        TableColumn("Avg") { server in
                            Text(Fmt.ms(server.stats.avgMs) ?? "—")
                        }
                        .width(min: 60, ideal: 80, max: 110)
                        TableColumn("Max") { server in
                            Text(Fmt.ms(server.stats.maxMs) ?? "—")
                        }
                        .width(min: 60, ideal: 80, max: 110)
                    }
                    .coreAuditTableHeight(rows: serversSeen.count)
                }
            }

            if hasOfferedOptions {
                KeyValueGroup("Offered options", rows: [
                    ("Router", Fmt.text(payload.offeredRouter)),
                    ("DNS", Fmt.list(payload.offeredDns)),
                    ("Domain", Fmt.text(payload.offeredDomain)),
                    ("Lease time", Fmt.leaseTime(payload.leaseTimeSeconds)),
                ])
            }

            if let utilization = payload.subnetUtilization {
                KeyValueGroup("Subnet utilisation", rows: [
                    ("Usable hosts", Fmt.int(utilization.usableHosts)),
                    ("Live hosts", Fmt.int(utilization.liveHosts)),
                    ("Utilisation", Fmt.percent(utilization.utilizationPercent)),
                    ("High utilisation", Fmt.yesNo(utilization.highUtilization)),
                    ("Note", Fmt.text(utilization.note)),
                ])
            }

            CoreAuditNote(text: payload.methodology)
        }
    }

    private var summaryRows: [(label: String, value: String?)] {
        var rows: [(label: String, value: String?)] = [
            ("Interface", interfaceText),
            ("DHCP server", Fmt.text(payload.serverIp)),
            ("Probes sent", Fmt.int(payload.probeCount)),
            ("Offers received", Fmt.int(payload.respondedCount)),
            ("Packet loss", Fmt.percent(payload.packetLossPercent)),
            ("Min / avg / max", minAvgMaxText),
            ("Response times", responseTimesText),
        ]
        if let method = payload.probeMethodDescription {
            rows.append(("Probe method", method))
        }
        if let mac = Fmt.text(payload.probeMac) {
            rows.append(("Probe MAC", mac))
        }
        if payload.probeOptions != nil || payload.intervalSeconds != nil {
            var parts: [String] = []
            if let options = Fmt.text(payload.probeOptions) { parts.append("options \(options)") }
            if let interval = Fmt.number(payload.intervalSeconds) { parts.append("\(interval) s between probes") }
            rows.append(("Probe settings", parts.joined(separator: ", ")))
        }
        if let unexpected = Fmt.list(payload.unexpectedServers) {
            rows.append(("Unexpected responders", unexpected))
        }
        return rows
    }

    private var respondersSubtitle: String? {
        guard let unexpected = Fmt.list(payload.unexpectedServers) else { return nil }
        return "Not seen by discovery (Task 4): \(unexpected)"
    }

    private var probeChart: some View {
        Chart {
            ForEach(responded) { probe in
                BarMark(
                    x: .value("Probe", "\(probe.id)"),
                    y: .value("Response time (ms)", probe.responseMs ?? 0),
                    width: .ratio(0.55)
                )
                .foregroundStyle(by: .value("Result", "Offer received"))
                .cornerRadius(3)
            }
            ForEach(lost) { probe in
                PointMark(
                    x: .value("Probe", "\(probe.id)"),
                    y: .value("Response time (ms)", 0.0)
                )
                .symbol(.cross)
                .symbolSize(70)
                .foregroundStyle(by: .value("Result", "Lost (no Offer)"))
            }
            if let average = payload.avgMs {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("avg \(Fmt.ms(average) ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale([
            "Offer received": CoreAuditChartPalette.series1,
            "Lost (no Offer)": CoreAuditChartPalette.critical,
        ])
        .chartXScale(domain: probes.map { "\($0.id)" })
        .chartYScale(domain: 0...yUpperBound)
        .chartXAxisLabel("Probe")
        .chartYAxisLabel("ms")
        .chartLegend(lost.isEmpty ? .hidden : .visible)
        .frame(height: 200)
    }

    private var interfaceText: String? {
        guard let interface = Fmt.text(payload.interface) else { return nil }
        return payload.isWifi == true ? "\(interface) (Wi-Fi)" : interface
    }

    private var minAvgMaxText: String? {
        let parts = [payload.minMs, payload.avgMs, payload.maxMs].map { Fmt.ms($0) }
        guard parts.contains(where: { $0 != nil }) else { return nil }
        return parts.map { $0 ?? "—" }.joined(separator: " / ")
    }

    private var responseTimesText: String? {
        guard !probes.isEmpty else { return nil }
        return probes.map { probe in
            probe.responseMs.map { Fmt.number($0) ?? "lost" } ?? "lost"
        }
        .joined(separator: ", ") + " ms"
    }
}
