import SwiftUI

/// The CoreWLAN row of the Task 17 panel: "Scan this room with CoreWLAN", the
/// live state, and the summary of the scan attached to the run.
struct WiFiScanRow: View {
    /// The scan handed to the engine (`--wifi-scan-json`); nil → the engine scans itself.
    @Binding var scan: WiFiScanResult?
    let scanner: WiFiScanner
    /// Wi-Fi device to scan; nil → CoreWLAN's default interface.
    let interface: String?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
                .font(.title3)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.vertical, 2)
        .task {
            guard WiFiScanner.consumeAutomationAutoScan() else { return }
            await runScan()
        }
    }

    // MARK: State presentation

    @ViewBuilder
    private var icon: some View {
        switch scanner.state {
        case .requestingAuthorization, .scanning:
            ProgressView().controlSize(.small)
        case .denied:
            Image(systemName: "location.slash.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle, .scanned:
            if let scan, scan.summary.networkCount > 0, !scan.summary.allNamesHidden {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if scan != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "wifi").foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch scanner.state {
        case .requestingAuthorization: return "Waiting for Location permission…"
        case .scanning: return "Scanning with CoreWLAN…"
        case .denied: return "Location access is off for LSS Network Tools"
        case .failed: return "The scan failed"
        case .idle, .scanned:
            guard let scan else { return "Not scanned yet" }
            let count = scan.summary.networkCount
            switch count {
            case 0: return "Room scanned — no networks found"
            case 1: return "Room scanned — 1 network"
            default: return "Room scanned — \(count) networks"
            }
        }
    }

    private var detail: String {
        switch scanner.state {
        case .requestingAuthorization:
            return "Answer the macOS prompt. CoreWLAN shows network names only to apps allowed to use Location."
        case .scanning:
            return "On \(scanner.requestedInterface ?? "the default Wi-Fi interface") — this takes a few seconds."
        case .denied:
            return "Allow it in System Settings › Privacy & Security › Location Services, then scan again." + keptSuffix
        case .failed(let message):
            return message + keptSuffix
        case .idle, .scanned:
            guard let scan else {
                return "Scans \(interface ?? "the default Wi-Fi interface") from this app and hands the networks to the engine."
            }
            let summary = scan.summary
            if summary.networkCount == 0 {
                return "The room will be recorded with no networks. Scan again, or remove the scan to let the engine scan. · " + Self.whereAndWhen(summary)
            }
            if summary.allNamesHidden {
                return "Every network name is hidden — check that LSS Network Tools is allowed in Location Services, then scan again. · " + Self.whereAndWhen(summary)
            }
            return Self.summaryLine(summary)
        }
    }

    private var detailIsWarning: Bool {
        switch scanner.state {
        case .denied, .failed: return true
        case .requestingAuthorization, .scanning: return false
        case .idle, .scanned:
            guard let summary = scan?.summary else { return false }
            return summary.networkCount == 0 || summary.allNamesHidden
        }
    }

    /// After a failed rescan the earlier scan is still the one the run uses.
    private var keptSuffix: String {
        guard let scan else { return "" }
        let count = scan.summary.networkCount
        return " The earlier scan (\(count) network\(count == 1 ? "" : "s")) stays attached."
    }

    @ViewBuilder
    private var actions: some View {
        switch scanner.state {
        case .denied:
            HStack(spacing: 8) {
                Button("Open Privacy Settings") { WiFiScanner.openLocationPrivacySettings() }
                Button("Try Again") { startScan() }
            }
        case .failed:
            Button("Try Again") { startScan() }
        case .requestingAuthorization, .scanning:
            Button(scan == nil ? "Scan this room with CoreWLAN" : "Scan Again") {}
                .disabled(true)
        case .idle, .scanned:
            if scan != nil {
                HStack(spacing: 8) {
                    Button("Scan Again") { startScan() }
                    Button {
                        removeScan()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this scan — the engine then scans with LSS-WiFiScan.app (sudo route only; the privileged helper cannot open it)")
                    .accessibilityLabel("Remove scan")
                }
            } else {
                Button("Scan this room with CoreWLAN") { startScan() }
                    .help("Scan the Wi-Fi networks visible here and hand them to the engine (--wifi-scan-json)")
            }
        }
    }

    // MARK: Actions

    private func startScan() {
        Task { await runScan() }
    }

    private func runScan() async {
        guard let result = await scanner.scan(interface: interface) else { return }
        // The replaced file was never used: the run has not started yet.
        if let previous = scan, previous.url != result.url {
            WiFiScanStore.remove(previous.url)
        }
        scan = result
    }

    private func removeScan() {
        if let scan { WiFiScanStore.remove(scan.url) }
        scan = nil
        scanner.reset()
    }

    // MARK: Formatting

    /// e.g. `12 SSIDs · 2 hidden · strongest -41 dBm (Office) · en0 · 14:32`
    static func summaryLine(_ summary: WiFiScanSummary) -> String {
        var parts = [summary.distinctSSIDCount == 1 ? "1 SSID" : "\(summary.distinctSSIDCount) SSIDs"]
        if summary.hiddenCount > 0 {
            parts.append("\(summary.hiddenCount) hidden")
        }
        if let rssi = summary.strongestRSSI {
            var strongest = "strongest \(rssi) dBm"
            if let ssid = summary.strongestSSID, ssid != WiFiNetworkRecord.hiddenSSID {
                strongest += " (\(ssid))"
            }
            parts.append(strongest)
        }
        parts.append(whereAndWhen(summary))
        return parts.joined(separator: " · ")
    }

    /// e.g. `en0 · 14:32` (`· from the scan cache` when the live scan gave nothing).
    static func whereAndWhen(_ summary: WiFiScanSummary) -> String {
        var text = "\(summary.interfaceName) · \(summary.scannedAt.formatted(date: .omitted, time: .shortened))"
        if summary.usedCachedResults {
            text += " · from the scan cache"
        }
        return text
    }
}
