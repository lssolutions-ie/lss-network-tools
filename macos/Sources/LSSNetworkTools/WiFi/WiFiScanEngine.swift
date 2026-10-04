import CoreWLAN
import Foundation

/// One network in the helper's JSON shape — the array `LSS-WiFiScan.app`
/// writes and `wireless_site_survey_noninteractive` reads with
/// `--wifi-scan-json` (`build_wifi_scan_helper_macos` in lss-network-tools.sh).
///
/// Every key is always present: `rssi_dbm` / `noise_floor_dbm` are `null` when
/// CoreWLAN reports 0 (the helper's `NSNull()`), never omitted.
struct WiFiNetworkRecord: Sendable, Hashable, Encodable {
    /// `"(hidden)"` when CoreWLAN gives no name.
    var ssid: String
    /// `"--"` when CoreWLAN gives no BSSID (no Location authorisation).
    var bssid: String
    var rssiDBM: Int?
    var noiseFloorDBM: Int?
    /// The channel number as a string, `""` when unknown.
    var channel: String
    /// `"2.4GHz"`, `"5GHz"`, `"6GHz"` or `""`.
    var band: String
    /// `"20MHz"`, `"40MHz"`, `"80MHz"`, `"160MHz"` or `""`.
    var channelWidth: String
    /// Always `"--"`: CoreWLAN's scan results do not expose them (same as the helper).
    var phyMode: String
    var security: String

    static let hiddenSSID = "(hidden)"
    static let unknownField = "--"

    enum CodingKeys: String, CodingKey {
        case ssid
        case bssid
        case rssiDBM = "rssi_dbm"
        case noiseFloorDBM = "noise_floor_dbm"
        case channel
        case band
        case channelWidth = "channel_width"
        case phyMode = "phy_mode"
        case security
    }

    /// Explicit `encode` (not the synthesised `encodeIfPresent`) so a missing
    /// signal value is written as `null` like the helper does.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ssid, forKey: .ssid)
        try container.encode(bssid, forKey: .bssid)
        try container.encode(rssiDBM, forKey: .rssiDBM)
        try container.encode(noiseFloorDBM, forKey: .noiseFloorDBM)
        try container.encode(channel, forKey: .channel)
        try container.encode(band, forKey: .band)
        try container.encode(channelWidth, forKey: .channelWidth)
        try container.encode(phyMode, forKey: .phyMode)
        try container.encode(security, forKey: .security)
    }
}

extension WiFiNetworkRecord {
    /// The helper's `scanViaCoreWLAN()` mapping, field for field.
    init(_ network: CWNetwork) {
        let channel = network.wlanChannel
        self.init(
            ssid: Self.nonEmpty(network.ssid) ?? Self.hiddenSSID,
            bssid: Self.nonEmpty(network.bssid) ?? Self.unknownField,
            rssiDBM: network.rssiValue != 0 ? network.rssiValue : nil,
            noiseFloorDBM: network.noiseMeasurement != 0 ? network.noiseMeasurement : nil,
            channel: channel.map { String($0.channelNumber) } ?? "",
            band: channel.map { Self.bandLabel($0.channelBand) } ?? "",
            channelWidth: channel.map { Self.widthLabel($0.channelWidth) } ?? "",
            phyMode: Self.unknownField,
            security: Self.unknownField
        )
    }

    /// `normBandCW` in the helper.
    static func bandLabel(_ band: CWChannelBand) -> String {
        switch band {
        case .band2GHz: "2.4GHz"
        case .band5GHz: "5GHz"
        case .band6GHz: "6GHz"
        case .bandUnknown: ""
        @unknown default: ""
        }
    }

    /// `normWidthCW` in the helper.
    static func widthLabel(_ width: CWChannelWidth) -> String {
        switch width {
        case .width20MHz: "20MHz"
        case .width40MHz: "40MHz"
        case .width80MHz: "80MHz"
        case .width160MHz: "160MHz"
        case .widthUnknown: ""
        @unknown default: ""
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

enum WiFiScanError: LocalizedError, Sendable, Equatable {
    case noWiFiInterface
    case wifiOff(interface: String)
    case scanFailed(interface: String, reason: String)
    case storeFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .noWiFiInterface:
            "This Mac has no Wi-Fi interface that CoreWLAN can use."
        case .wifiOff(let interface):
            "Wi-Fi is turned off on \(interface). Turn it on and scan again."
        case .scanFailed(let interface, let reason):
            "CoreWLAN could not scan on \(interface): \(reason)"
        case .storeFailed(let reason):
            "The scan could not be saved: \(reason)"
        }
    }
}

/// What one CoreWLAN pass produced.
struct WiFiScanOutcome: Sendable {
    var interfaceName: String
    var networks: [WiFiNetworkRecord]
    /// True when the live scan failed or came back empty and the system's
    /// background scan cache was used instead (the helper's fallback).
    var usedCachedResults: Bool
}

/// The CoreWLAN half of `LSS-WiFiScan.app`. Synchronous and slow (a live scan
/// takes a few seconds): call it off the main actor.
enum WiFiScanEngine {
    /// Scans `interfaceName` when CoreWLAN knows it as a Wi-Fi interface,
    /// otherwise the default Wi-Fi interface.
    static func scan(interfaceName: String?) throws -> WiFiScanOutcome {
        let client = CWWiFiClient.shared()
        let known = client.interfaceNames() ?? []
        let interface: CWInterface?
        if let interfaceName, known.contains(interfaceName) {
            interface = client.interface(withName: interfaceName)
        } else {
            interface = client.interface()
        }
        guard let interface, let name = interface.interfaceName else {
            throw WiFiScanError.noWiFiInterface
        }
        guard interface.powerOn() else {
            throw WiFiScanError.wifiOff(interface: name)
        }

        // Live scan first; fall back to the background-scan cache when the scan
        // fails or returns nothing — exactly the helper's order.
        var networks: Set<CWNetwork> = []
        var scanError: (any Error)?
        do {
            networks = try interface.scanForNetworks(withSSID: nil)
        } catch {
            scanError = error
        }
        var usedCache = false
        if networks.isEmpty, let cached = interface.cachedScanResults(), !cached.isEmpty {
            networks = cached
            usedCache = true
        }
        if networks.isEmpty, let scanError {
            throw WiFiScanError.scanFailed(interface: name, reason: scanError.localizedDescription)
        }

        // Strongest first, then by name: a stable, readable file.
        let records = networks.map(WiFiNetworkRecord.init).sorted { lhs, rhs in
            let l = lhs.rssiDBM ?? Int.min
            let r = rhs.rssiDBM ?? Int.min
            if l != r { return l > r }
            if lhs.ssid != rhs.ssid { return lhs.ssid < rhs.ssid }
            return lhs.bssid < rhs.bssid
        }
        return WiFiScanOutcome(interfaceName: name, networks: records, usedCachedResults: usedCache)
    }
}
