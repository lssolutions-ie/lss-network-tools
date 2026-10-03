import SwiftUI
import Charts
import LSSCore

/// Task 17 — survey summary, a room picker, the RSSI bar chart for the selected
/// room and the room's networks table.
struct WirelessSurveyDetailView: View {
    let task: TaskID
    let payload: WirelessSurveyPayload

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedRoom = 0
    @State private var hoveredNetwork: Int?
    @State private var sortOrder = [KeyPathComparator(\NetworkRow.signalSortKey, order: .reverse)]

    private struct NetworkRow: Identifiable {
        let id: Int
        let network: WirelessSurveyPayload.Network
        /// Chart category label, unique within the room.
        let label: String

        var ssid: String { network.displaySSID }
        var bssid: String { Fmt.text(network.bssid) ?? "" }
        var signal: Double? { network.signalDbm }
        var signalSortKey: Double { signal ?? -.infinity }
        var channel: String { Fmt.text(network.channel) ?? "" }
        var channelSortKey: Int { network.channelNumber ?? .max }
        var band: String { network.bandLabel ?? "" }
        var width: String { Fmt.text(network.channelWidth) ?? "" }
        var security: String { Fmt.text(network.security) ?? "" }
        var bandCategory: String { band.isEmpty ? WirelessBand.unknown : band }
    }

    /// Categorical slots 1–3 of the data-viz palette (validated all-pairs in both modes).
    private enum WirelessBand {
        static let unknown = "Unknown band"
        static let order = ["2.4GHz", "5GHz", "6GHz", unknown]

        static func color(_ band: String, dark: Bool) -> Color {
            switch band {
            case "2.4GHz": .specialistHex(dark ? 0x3987E5 : 0x2A78D6)
            case "5GHz": .specialistHex(dark ? 0xD95926 : 0xEB6834)
            case "6GHz": .specialistHex(dark ? 0x199E70 : 0x1BAF7A)
            default: Color.gray
            }
        }
    }

    // MARK: Derived data

    private var rooms: [WirelessSurveyPayload.Room] { payload.survey ?? [] }

    private var roomIndex: Int { min(max(selectedRoom, 0), max(rooms.count - 1, 0)) }

    private var room: WirelessSurveyPayload.Room? {
        rooms.indices.contains(roomIndex) ? rooms[roomIndex] : nil
    }

    /// Networks of the selected room. Several radios usually share one SSID, so
    /// the chart label gets the BSSID (or an ordinal) appended when needed.
    private var rows: [NetworkRow] {
        let networks = room?.networks ?? []
        var ssidCounts: [String: Int] = [:]
        for network in networks { ssidCounts[network.displaySSID, default: 0] += 1 }
        var usedLabels: Set<String> = []
        return networks.enumerated().map { index, network in
            let ssid = network.displaySSID
            var label = ssid
            if ssidCounts[ssid, default: 0] > 1 {
                label = Fmt.text(network.bssid).map { "\(ssid) · \($0)" } ?? "\(ssid) · #\(index + 1)"
            }
            while usedLabels.contains(label) { label += " " }
            usedLabels.insert(label)
            return NetworkRow(id: index, network: network, label: label)
        }
    }

    /// Rows with a signal, strongest first — the chart's order.
    private var chartRows: [NetworkRow] {
        rows.filter { $0.signal != nil }.sorted { ($0.signal ?? 0) > ($1.signal ?? 0) }
    }

    private var strongest: NetworkRow? { chartRows.first }

    private var bandsPresent: [String] {
        WirelessBand.order.filter { band in chartRows.contains { $0.bandCategory == band } }
    }

    /// Bars grow from the noise-level floor towards 0; weaker than -100 dBm widens the floor.
    private var chartFloor: Double {
        let weakest = chartRows.compactMap(\.signal).min() ?? -100
        return min(-100, (weakest / 10).rounded(.down) * 10)
    }

    private var sortedRows: [NetworkRow] { rows.sorted(using: sortOrder) }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            KeyValueGroup("Survey", rows: [
                ("Interface", Fmt.text(payload.interface)),
                ("Rooms scanned", Fmt.int(payload.roomsScanned ?? (payload.survey == nil ? nil : rooms.count))),
                ("Networks recorded", Fmt.int(payload.survey == nil ? nil : payload.allNetworks.count)),
                ("Distinct SSIDs", Fmt.int(payload.survey == nil ? nil : Set(payload.allNetworks.filter { !$0.isHidden }.map(\.displaySSID)).count)),
                ("Distinct BSSIDs", Fmt.int(payload.survey == nil ? nil : Set(payload.allNetworks.compactMap { Fmt.text($0.bssid) }).count)),
            ])

            if rooms.isEmpty {
                SpecialistEmptyNote("No rooms were recorded.")
            } else {
                Picker("Room", selection: $selectedRoom) {
                    ForEach(Array(rooms.enumerated()), id: \.offset) { index, room in
                        Text(room.displayName).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 420, alignment: .leading)
                .onChange(of: rooms.count) {
                    selectedRoom = 0
                    hoveredNetwork = nil
                }

                if let room {
                    roomSummary(room)
                    SectionCard("Signal strength", subtitle: "RSSI per network in \(room.displayName); stronger signals reach further right") {
                        chart
                    }
                    SectionCard("Networks", subtitle: "\(rows.count) visible from this position") {
                        networksTable
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func roomSummary(_ room: WirelessSurveyPayload.Room) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            KeyValueGroup("Position", rows: [
                ("Building", Fmt.text(room.building)),
                ("Floor", Fmt.text(room.floor)),
                ("Room / area", Fmt.text(room.room)),
                ("AP label", Fmt.text(room.apLabel)),
                ("Scanned at", room.timestampDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? Fmt.text(room.timestamp)),
                ("Strongest", strongest.map { "\($0.ssid) (\(SpecialistFmt.dbm($0.signal) ?? "—"))" }),
            ])
            FlagBadge(label: "Access point physically present in this room", value: room.apPresent)
        }
    }

    @ViewBuilder
    private var chart: some View {
        if chartRows.isEmpty {
            SpecialistEmptyNote(rows.isEmpty
                ? "No networks were recorded in this room."
                : "The scanner reported no signal strength for the networks in this room.")
        } else {
            let dark = colorScheme == .dark
            let bands = bandsPresent
            VStack(alignment: .leading, spacing: 6) {
                Chart(chartRows) { row in
                    BarMark(
                        xStart: .value("Floor", chartFloor),
                        xEnd: .value("RSSI (dBm)", row.signal ?? chartFloor),
                        y: .value("Network", row.label),
                        height: .fixed(16)
                    )
                    .foregroundStyle(by: .value("Band", row.bandCategory))
                    .cornerRadius(4)
                    .opacity(hoveredNetwork == nil || hoveredNetwork == row.id ? 1 : 0.35)
                    .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                        if row.id == strongest?.id || row.id == hoveredNetwork {
                            Text(SpecialistFmt.dbm(row.signal) ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .chartXScale(domain: chartFloor ... -20)
                .chartXAxisLabel("RSSI (dBm)")
                .chartXAxis {
                    AxisMarks(values: .stride(by: 10)) {
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .chartYAxis {
                    AxisMarks { AxisValueLabel() }
                }
                .chartForegroundStyleScale(domain: bands, range: bands.map { WirelessBand.color($0, dark: dark) })
                .chartLegend(bands.count > 1 ? .visible : .hidden)
                .chartLegend(position: .top, alignment: .leading)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let plotFrame = proxy.plotFrame else {
                                        hoveredNetwork = nil
                                        return
                                    }
                                    let frame = geometry[plotFrame]
                                    guard frame.contains(location),
                                          let label: String = proxy.value(atY: location.y - frame.minY) else {
                                        hoveredNetwork = nil
                                        return
                                    }
                                    hoveredNetwork = chartRows.first { $0.label == label }?.id
                                case .ended:
                                    hoveredNetwork = nil
                                }
                            }
                    }
                }
                .frame(height: CGFloat(chartRows.count) * 26 + 64)

                Text(hoverDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if chartRows.count < rows.count {
                    Text("\(rows.count - chartRows.count) network(s) without a reported signal are listed in the table only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var hoverDetail: String {
        guard let hoveredNetwork, let row = rows.first(where: { $0.id == hoveredNetwork }) else {
            return "Hover over a bar for details."
        }
        var parts = [row.ssid]
        if !row.bssid.isEmpty { parts.append(row.bssid) }
        if let signal = SpecialistFmt.dbm(row.signal) { parts.append(signal) }
        if let noise = SpecialistFmt.dbm(row.network.noiseFloorDbm) { parts.append("noise \(noise)") }
        if !row.channel.isEmpty { parts.append("ch \(row.channel)") }
        if !row.band.isEmpty { parts.append(row.band) }
        if !row.width.isEmpty { parts.append(row.width) }
        if !row.security.isEmpty { parts.append(row.security) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var networksTable: some View {
        if rows.isEmpty {
            SpecialistEmptyNote("No networks were recorded in this room.")
        } else {
            Table(sortedRows, sortOrder: $sortOrder) {
                TableColumn("SSID", value: \.ssid) { row in
                    Text(row.ssid)
                        .foregroundStyle(row.network.isHidden ? Color.secondary : Color.primary)
                }
                TableColumn("BSSID", value: \.bssid) { row in
                    Text(row.bssid.isEmpty ? "—" : row.bssid)
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 140, ideal: 150, max: 170)
                TableColumn("RSSI", value: \.signalSortKey) { row in
                    Text(SpecialistFmt.dbm(row.signal) ?? "—").monospacedDigit()
                }
                .width(min: 70, ideal: 80, max: 100)
                TableColumn("Noise") { row in
                    Text(SpecialistFmt.dbm(row.network.noiseFloorDbm) ?? "—").monospacedDigit()
                }
                .width(min: 70, ideal: 80, max: 100)
                TableColumn("Channel", value: \.channelSortKey) { row in
                    Text(row.channel.isEmpty ? "—" : row.channel).monospacedDigit()
                }
                .width(min: 60, ideal: 70, max: 90)
                TableColumn("Band", value: \.band) { row in
                    Text(row.band.isEmpty ? "—" : row.band)
                }
                .width(min: 60, ideal: 70, max: 90)
                TableColumn("Width", value: \.width) { row in
                    Text(row.width.isEmpty ? "—" : row.width)
                }
                .width(min: 60, ideal: 80, max: 110)
                TableColumn("Security", value: \.security) { row in
                    Text(row.security.isEmpty ? "—" : row.security)
                }
            }
            .specialistTableHeight(rows: rows.count)
        }
    }
}
