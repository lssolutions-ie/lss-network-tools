import Charts
import LSSCore
import SwiftUI

/// Tasks 10 and 14 — Gateway / Custom Target Stress Test: stage outcomes,
/// indicators, latency per stage, and the ramping test (latency and loss per
/// packet size). Failure-only files show the target and a short note.
struct StressTestDetailView: View {
    let task: TaskID
    let payload: StressTestPayload

    private struct RampRow: Identifiable {
        let id: Int
        let step: StressTestPayload.RampingStep
    }

    /// The five stages that write summary metrics (ramping is per packet size).
    private var measured: [StressTestPayload.StageSummary] {
        payload.stages.filter { $0.kind != .ramping && $0.metrics != nil }
    }

    private var ramping: [StressTestPayload.RampingStep] { payload.rampingTest ?? [] }

    private var rampRows: [RampRow] {
        ramping.enumerated().map { RampRow(id: $0.offset, step: $0.element) }
    }

    private var targetLabel: String { task == .customStress ? "Target IP" : "Gateway" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyValueGroup("Target", rows: [
                (targetLabel, Fmt.text(payload.target)),
                ("Hostname", Fmt.text(payload.hostname)),
                ("Interface", Fmt.text(payload.interface)),
                ("Completed with warnings", Fmt.yesNo(payload.completedWithWarnings)),
            ])

            if payload.stageStatus != nil {
                HStack(spacing: 8) {
                    ForEach(payload.stages) { stage in
                        StagePill(title: stage.title, status: stage.status)
                    }
                }
            }

            if let indicators = payload.indicators {
                HStack(spacing: 16) {
                    FlagBadge(label: "High jitter", value: indicators.highJitter, highlightTrue: true)
                    FlagBadge(label: "Latency under load", value: indicators.latencyUnderLoad, highlightTrue: true)
                    FlagBadge(label: "Packet loss", value: indicators.packetLoss, highlightTrue: true)
                    FlagBadge(label: "Slow recovery", value: indicators.slowRecovery, highlightTrue: true)
                    if let returned = payload.recovery?.returnedToBaseline {
                        FlagBadge(
                            label: returned ? "Returned to baseline" : "Did not return to baseline",
                            value: true,
                            highlightTrue: !returned
                        )
                    }
                }
            }

            if !payload.hasMeasurements {
                CoreAuditEmptyNote("No stage measurements were recorded — the test ended before the baseline stage completed.")
            }

            if !measured.isEmpty {
                SectionCard("Latency by stage", subtitle: "Average and maximum ICMP round-trip time per stage") {
                    stageChart
                    Table(measured) {
                        TableColumn("Stage") { stage in
                            Text(stage.title)
                        }
                        TableColumn("Avg latency") { stage in
                            Text(Fmt.ms(stage.metrics?.avgLatencyMs) ?? "—")
                        }
                        TableColumn("Max latency") { stage in
                            Text(Fmt.ms(stage.metrics?.maxLatencyMs) ?? "—")
                        }
                        TableColumn("Std dev") { stage in
                            Text(Fmt.ms(stage.metrics?.stddevMs) ?? "—")
                        }
                        TableColumn("Packet loss") { stage in
                            Text(Fmt.percent(stage.metrics?.packetLossPercent) ?? "—")
                        }
                    }
                    .coreAuditTableHeight(rows: measured.count)
                }
            }

            if !ramping.isEmpty {
                SectionCard("Ramping test", subtitle: "20 pings per packet size — latency above, packet loss below") {
                    rampingLatencyChart
                    rampingLossChart
                    Table(rampRows) {
                        TableColumn("Packet size") { row in
                            Text(sizeLabel(row.step))
                        }
                        TableColumn("Avg latency") { row in
                            Text(Fmt.ms(row.step.avgLatencyMs) ?? "—")
                        }
                        TableColumn("Max latency") { row in
                            Text(Fmt.ms(row.step.maxLatencyMs) ?? "—")
                        }
                        TableColumn("Packet loss") { row in
                            Text(Fmt.percent(row.step.packetLossPercent) ?? "—")
                        }
                    }
                    .coreAuditTableHeight(rows: rampRows.count)
                }
            }

            CoreAuditNote(text: payload.methodology)
        }
    }

    // MARK: Charts

    private var stageChart: some View {
        Chart {
            ForEach(measured) { stage in
                if let average = stage.metrics?.avgLatencyMs {
                    BarMark(x: .value("Stage", stage.title), y: .value("Latency (ms)", average))
                        .foregroundStyle(by: .value("Metric", "Average"))
                        .position(by: .value("Metric", "Average"))
                        .cornerRadius(3)
                }
                if let peak = stage.metrics?.maxLatencyMs {
                    BarMark(x: .value("Stage", stage.title), y: .value("Latency (ms)", peak))
                        .foregroundStyle(by: .value("Metric", "Maximum"))
                        .position(by: .value("Metric", "Maximum"))
                        .cornerRadius(3)
                }
            }
        }
        .chartForegroundStyleScale(["Average": CoreAuditChartPalette.series1, "Maximum": CoreAuditChartPalette.series2])
        .chartXScale(domain: measured.map(\.title))
        .chartYAxisLabel("ms")
        .frame(height: 200)
    }

    private var rampingLatencyChart: some View {
        Chart {
            ForEach(rampRows) { row in
                if let average = row.step.avgLatencyMs {
                    LineMark(
                        x: .value("Packet size", sizeLabel(row.step)),
                        y: .value("Latency (ms)", average),
                        series: .value("Metric", "Average")
                    )
                    .foregroundStyle(by: .value("Metric", "Average"))
                    PointMark(x: .value("Packet size", sizeLabel(row.step)), y: .value("Latency (ms)", average))
                        .foregroundStyle(by: .value("Metric", "Average"))
                }
                if let peak = row.step.maxLatencyMs {
                    LineMark(
                        x: .value("Packet size", sizeLabel(row.step)),
                        y: .value("Latency (ms)", peak),
                        series: .value("Metric", "Maximum")
                    )
                    .foregroundStyle(by: .value("Metric", "Maximum"))
                    PointMark(x: .value("Packet size", sizeLabel(row.step)), y: .value("Latency (ms)", peak))
                        .foregroundStyle(by: .value("Metric", "Maximum"))
                }
            }
        }
        .chartForegroundStyleScale(["Average": CoreAuditChartPalette.series1, "Maximum": CoreAuditChartPalette.series2])
        .chartXScale(domain: ramping.map(sizeLabel))
        .chartYAxisLabel("ms")
        .frame(height: 180)
    }

    private var rampingLossChart: some View {
        let peakLoss = ramping.compactMap(\.packetLossPercent).max() ?? 0
        return Chart {
            ForEach(rampRows) { row in
                let loss = row.step.packetLossPercent ?? 0
                BarMark(
                    x: .value("Packet size", sizeLabel(row.step)),
                    y: .value("Packet loss (%)", loss),
                    width: .ratio(0.5)
                )
                .foregroundStyle(loss > 0 ? CoreAuditChartPalette.critical : CoreAuditChartPalette.neutral)
                .cornerRadius(3)
            }
        }
        .chartXScale(domain: ramping.map(sizeLabel))
        .chartYScale(domain: 0...max(5, peakLoss * 1.3))
        .chartYAxisLabel("% loss")
        .frame(height: 110)
    }

    private func sizeLabel(_ step: StressTestPayload.RampingStep) -> String {
        step.packetSize.map { "\($0) B" } ?? "?"
    }
}

/// One stage of the status strip: `ok` green, `failed` red, `partial` orange,
/// anything else (including a missing status) grey.
private struct StagePill: View {
    let title: String
    let status: String?

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .help("\(title): \(status ?? "not run")")
    }

    private var color: Color {
        switch status {
        case "ok": .green
        case "failed": .red
        case "partial": .orange
        default: .secondary
        }
    }

    private var symbol: String {
        switch status {
        case "ok": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "partial": "exclamationmark.triangle.fill"
        default: "questionmark.circle"
        }
    }
}
