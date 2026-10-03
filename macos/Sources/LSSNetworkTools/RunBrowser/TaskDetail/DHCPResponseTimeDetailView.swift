import Charts
import LSSCore
import SwiftUI

/// Task 5 — DHCP Response Time: Discover→Offer latency per probe (lost probes
/// marked), summary statistics, indicators and the subnet utilisation estimate.
struct DHCPResponseTimeDetailView: View {
    let task: TaskID
    let payload: DHCPResponseTimePayload

    private var probes: [DHCPResponseTimePayload.ProbeSample] { payload.probes }
    private var responded: [DHCPResponseTimePayload.ProbeSample] { probes.filter { !$0.isLost } }
    private var lost: [DHCPResponseTimePayload.ProbeSample] { probes.filter(\.isLost) }

    /// Keeps the chart readable when every probe was lost (no bars to scale to).
    private var yUpperBound: Double {
        let peak = responded.compactMap(\.responseMs).max() ?? 0
        return max(peak * 1.15, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyValueGroup("Summary", rows: [
                ("Interface", interfaceText),
                ("DHCP server", Fmt.text(payload.serverIp)),
                ("Probes sent", Fmt.int(payload.probeCount)),
                ("Offers received", Fmt.int(payload.respondedCount)),
                ("Packet loss", Fmt.percent(payload.packetLossPercent)),
                ("Min / avg / max", minAvgMaxText),
                ("Response times", responseTimesText),
            ])

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
                }
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
