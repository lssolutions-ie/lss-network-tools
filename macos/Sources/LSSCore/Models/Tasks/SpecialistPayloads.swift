import Foundation

// Payload models for the custom-target and specialist tasks (13, 15–20),
// decoded with `LSSJSON.decoder()` (snake_case → camelCase). Field names
// mirror the jq writers in lss-network-tools.sh. Every property is optional:
// the failure files of Tasks 15/16 carry only `target_ip`/`hostname`, Task 18's
// `no_subnet` file has no `false_positives`, and Tasks 19/20 omit `warnings`
// entirely (research 03 §13–20, hazards 4–5). Task 14 shares
// `StressTestPayload` with Task 10 and lives in CoreAuditPayloads.swift.

// MARK: - Task 13: Custom Target Port Scan

/// `custom-target-port-scan-device-N.json`, written by `custom_target_port_scan()`.
public struct CustomPortScanPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.customPortScan]

    public let targetIp: String?
    /// PTR name of the target, or `"unknown"`.
    public let hostname: String?
    /// Always `"custom_target_port_scan"`.
    public let scanType: String?
    /// Open TCP ports (nmap `-p- --open`); `[]` when nothing was open and on failure.
    public let openPorts: [Int]?
}

// MARK: - Task 15: Custom Target Identity Scan

/// `custom-target-identity-scan-device-N.json`, written by `custom_target_identity_scan()`.
/// Failure files (`tempfile_creation_failed`, `custom_identity_discovery_failed`,
/// `custom_identity_fingerprint_failed`) contain only `targetIp` and `hostname`.
public struct IdentityScanPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.customIdentity]

    public let targetIp: String?
    public let hostname: String?
    /// Uppercase `AA:BB:CC:DD:EE:FF`, or `nil` when no MAC could be found.
    public let macAddress: String?
    /// Vendor name, or `"unknown"`.
    public let vendor: String?
    /// `nmap` | `macvendors-api` | `unknown`.
    public let vendorSource: String?
    /// `nmap` | `arp-cache`.
    public let lookupMethod: String?
    /// `up` | `down` | `unknown`.
    public let hostState: String?
    /// A hint from `guess_device_type_from_identity()`: `printer`, `windows-host`,
    /// `nas-or-file-server`, `firewall-or-router`, `network-switch`,
    /// `access-point-or-router`, `linux-host`, `camera-or-nvr`, `network-device`,
    /// `iot-device-or-smart-relay` or `unknown`.
    public let deviceTypeHint: String?
    /// `high` | `medium` | `low`.
    public let confidence: String?
    /// `build_identity_summary()` text, e.g. "Likely network printer".
    public let identitySummary: String?
    public let services: [Service]?

    /// One row of the `nmap -sV --version-light` port table.
    public struct Service: Decodable, Sendable, Hashable {
        /// Port and transport in one string, e.g. `"22/tcp"`.
        public let port: String?
        public let state: String?
        public let service: String?
        /// Version banner; `""` when nmap printed none.
        public let version: String?

        /// Numeric part of `port` (`"22/tcp"` → 22).
        public var portNumber: Int? {
            guard let port else { return nil }
            return Int(port.prefix { $0.isNumber })
        }

        /// Transport part of `port` (`"22/tcp"` → `"tcp"`).
        public var transport: String? {
            guard let port, let slash = port.firstIndex(of: "/") else { return nil }
            let proto = port[port.index(after: slash)...]
            return proto.isEmpty ? nil : String(proto)
        }
    }

    /// `deviceTypeHint` with hyphens turned into spaces; `nil` for `unknown`.
    public var deviceTypeLabel: String? {
        Sentinel.value(deviceTypeHint)?.replacingOccurrences(of: "-", with: " ")
    }
}

// MARK: - Task 16: Custom Target DNS Assessment

/// `custom-target-dns-assessment-device-N.json`, written by `custom_target_dns_assessment()`.
/// The `dns_query_tool_missing` failure file contains only `targetIp` and `hostname`.
public struct DNSAssessmentPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.customDNS]

    public let targetIp: String?
    public let hostname: String?
    /// `dig` | `nslookup`.
    public let queryTool: String?
    public let dnsServiceWorking: Bool?
    public let recursionAvailable: Bool?
    /// `example.com A` over UDP.
    public let udpQuery: Query?
    /// `example.com A` over TCP (`status: "unknown"` with nslookup).
    public let tcpQuery: Query?
    /// Reverse lookup of 8.8.8.8.
    public let reversePtrQuery: Query?
    /// `version.bind TXT CH` answer, or `nil` when the server did not disclose one.
    public let versionBindResponse: String?
    /// `versionBindResponse`, or `"unknown"`.
    public let softwareHint: String?
    /// Always `"unknown"`: the script cannot observe upstream forwarding from a client.
    public let upstreamDestinationInference: String?
    public let upstreamVisibilityNote: String?

    public struct Query: Decodable, Sendable, Hashable {
        /// dig rcode (`NOERROR`, `REFUSED`, `SERVFAIL`, …) or `"unknown"`.
        public let status: String?
        /// Last column of each ANSWER SECTION row; always empty with nslookup.
        public let answers: [String]?
    }
}

// MARK: - Task 17: Wireless Site Survey

/// `wireless-survey.json`, written by `wireless_site_survey()`.
public struct WirelessSurveyPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.wirelessSurvey]

    /// Always `"wireless_site_survey"`.
    public let scanType: String?
    /// Wireless interface used; `nil` in the `NO_WIRELESS_INTERFACE` failure file.
    public let interface: String?
    @LenientInt public var roomsScanned: Int?
    public let survey: [Room]?

    /// One scan position.
    public struct Room: Decodable, Sendable, Hashable {
        public let building: String?
        public let floor: String?
        public let room: String?
        public let apPresent: Bool?
        /// AP label typed by the surveyor; `nil` when skipped or when no AP is present.
        public let apLabel: String?
        /// ISO-8601 UTC, e.g. `2026-06-11T09:42:17Z`.
        public let timestamp: String?
        public let networks: [Network]?

        public var timestampDate: Date? { timestamp.flatMap(LSSJSON.parseISO8601) }

        /// "Building · Floor · Room" from whichever parts were entered.
        public var displayName: String {
            let parts = [building, floor, room].compactMap { Sentinel.value($0) }
            return parts.isEmpty ? "Unnamed location" : parts.joined(separator: " · ")
        }
    }

    /// One visible network. Key sets differ by scanner (research 03 §17): the
    /// CoreWLAN helper writes all nine keys with `phyMode`/`security` = `"--"`,
    /// system_profiler writes `bssid` = `"--"`, Linux `iw` defaults `rssiDbm` to
    /// `0`, and the legacy airport scanner writes only the first five.
    public struct Network: Decodable, Sendable, Hashable {
        /// Network name; `"(hidden)"` (or `""` from `iw`) when not broadcast.
        public let ssid: String?
        /// Lowercase MAC of the radio, or `"--"` from system_profiler.
        public let bssid: String?
        /// Signal in dBm; `nil` when the scanner reported none, `0` from `iw` when unknown.
        @Lenient public var rssiDbm: Double?
        /// Channel as text: `"36"`, or airport-style `"36,+1"` / `"149,80"`.
        @LenientString public var channel: String?
        /// `WPA2`, `WPA2-Enterprise`, `WPA3`, `Open`, airport-style `WPA2(PSK/AES/AES)`, or `"--"`.
        public let security: String?
        @Lenient public var noiseFloorDbm: Double?
        /// `2.4GHz` | `5GHz` | `6GHz` | `""`.
        public let band: String?
        /// `20MHz` … `160MHz`, `iw`-style `"1 (80 MHz)"`, or `""`.
        public let channelWidth: String?
        public let phyMode: String?

        /// True for `(hidden)`, `<hidden>`, blank or missing SSIDs.
        public var isHidden: Bool {
            guard let ssid else { return true }
            let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == "(hidden)" || trimmed == "<hidden>"
        }

        /// SSID for display; hidden networks read "Hidden network".
        public var displaySSID: String {
            guard !isHidden, let ssid else { return "Hidden network" }
            return ssid
        }

        /// `rssiDbm` with the Linux `0` placeholder treated as unknown.
        public var signalDbm: Double? {
            guard let rssiDbm, rssiDbm != 0 else { return nil }
            return rssiDbm
        }

        /// Leading number of `channel` (`"36,+1"` → 36).
        public var channelNumber: Int? {
            guard let channel else { return nil }
            return Int(channel.prefix { $0.isNumber })
        }

        /// `band`, or — for scanners that do not report one — 2.4 GHz for channels
        /// 1–14 and 5 GHz above that (6 GHz radios always report their band).
        public var bandLabel: String? {
            if let band = Sentinel.value(band) { return band }
            guard let channel = channelNumber else { return nil }
            return channel <= 14 ? "2.4GHz" : "5GHz"
        }
    }

    /// Every network of every room, in survey order.
    public var allNetworks: [Network] { survey?.flatMap { $0.networks ?? [] } ?? [] }
}

// MARK: - Task 18: Scan For UniFi Devices

/// `unifi-discovery.json`, written by `unifi_device_scan()`.
public struct UniFiDiscoveryPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.unifiDiscovery]

    public let interface: String?
    /// Broadcast address probed on UDP 10001; missing in failure files.
    public let broadcast: String?
    /// CIDR scanned, or `""` when it could not be determined.
    public let subnet: String?
    /// `devices.count`, probable devices included (research 03, hazard 17).
    @LenientInt public var devicesFound: Int?
    public let devices: [Device]?
    /// Hosts that answered UDP 10001 or LLDP but carry a non-Ubiquiti MAC. The key
    /// is missing in the `no_subnet` and `missing_dependency` failure files.
    public let falsePositives: [Device]?

    /// A discovered host; `false_positives` rows carry only `mac` and `ip`.
    public struct Device: Decodable, Sendable, Hashable {
        /// Lowercase MAC, or `"unknown"` when ARP never resolved it.
        public let mac: String?
        public let ip: String?
        /// TLV short model name (`U6-LR`, `USW-24-PoE`); missing when the device never answered a probe.
        public let model: String?
        /// `"probable"` for hosts matched only by a Dropbear SSH banner; missing means confirmed.
        public let confidence: String?

        public var isProbable: Bool { confidence == "probable" }
    }

    /// Devices confirmed by TLV, OUI or LLDP — the ones Task 19 adopts.
    public var confirmedDevices: [Device] { devices?.filter { !$0.isProbable } ?? [] }
    /// Devices flagged from an SSH banner alone.
    public var probableDevices: [Device] { devices?.filter(\.isProbable) ?? [] }
}

// MARK: - Task 19: UniFi Adoption

/// `unifi-adoption.json`, written by `unifi_adoption()`. The file has no `warnings`
/// key, and `status` is `"success"` even when every adoption failed.
public struct UniFiAdoptionPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.unifiAdoption]

    /// Controller host as entered, scheme and port stripped.
    public let controller: String?
    /// `http(s)://host:port/inform` sent with `mca-cli-op set-inform`.
    public let informUrl: String?
    public let interface: String?
    /// Confirmed devices loaded from Task 18 (probable ones are never adopted).
    @LenientInt public var devicesFound: Int?
    @LenientInt public var devicesAdopted: Int?
    public let devices: [Device]?

    public struct Device: Decodable, Sendable, Hashable {
        public let ip: String?
        /// `"adopted"` or `"failed: <reason>"`.
        public let result: String?

        public var isAdopted: Bool { result == "adopted" }

        /// The text after `failed:`, or the raw result for an unknown failure string.
        public var failureReason: String? {
            guard let result, !isAdopted else { return nil }
            let text = result.hasPrefix("failed:") ? String(result.dropFirst("failed:".count)) : result
            return text.trimmingCharacters(in: .whitespaces)
        }
    }

    public var failedDevices: [Device] { devices?.filter { !$0.isAdopted } ?? [] }
}

// MARK: - Task 20: Find Device by MAC

/// `find-device-by-mac.json`, written by `find_device_by_mac()`. No `warnings` key.
public struct FindByMACPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.findByMAC]

    /// Normalised lowercase `aa:bb:cc:dd:ee:ff`.
    public let macQueried: String?
    /// IPv4 address currently using the MAC; `nil` when it was not seen.
    public let ipFound: String?
    public let interface: String?
    /// CIDR scanned; `""` in the `no_subnet` failure file.
    public let subnet: String?

    public var isFound: Bool { Sentinel.value(ipFound) != nil }
}

// MARK: - Decoding entry point

/// Decodes the payload of Task 13 or 15–20 together with its envelope. Returns
/// `nil` for every other task — including 10 and 14, whose shared
/// `StressTestPayload` is decoded by `decodeCoreAuditPayload`.
public func decodeSpecialistPayload(task: TaskID, data: Data) throws -> (TaskEnvelope, any TaskPayload)? {
    func decode<P: TaskPayload>(_: P.Type) throws -> (TaskEnvelope, any TaskPayload) {
        let result = try LSSJSON.decode(TaskResult<P>.self, from: data)
        return (result.envelope, result.payload)
    }

    switch task {
    case .customPortScan: return try decode(CustomPortScanPayload.self)
    case .customIdentity: return try decode(IdentityScanPayload.self)
    case .customDNS: return try decode(DNSAssessmentPayload.self)
    case .wirelessSurvey: return try decode(WirelessSurveyPayload.self)
    case .unifiDiscovery: return try decode(UniFiDiscoveryPayload.self)
    case .unifiAdoption: return try decode(UniFiAdoptionPayload.self)
    case .findByMAC: return try decode(FindByMACPayload.self)
    default: return nil
    }
}
