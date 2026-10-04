import Foundation

// Task-specific payloads for the core audit (tasks 1–12) plus the custom
// target stress test (task 14, which shares `StressTestPayload` with task 10).
//
// Shapes follow docs/research/03-json-schemas.md and the jq writers in
// lss-network-tools.sh. Every property is optional because failure files are
// minimal (tasks 10/11/14 write only the envelope), keys appeared over time
// (`isp_name`, `subnet_utilization`, `smb_signing_required`, DNS enrichment)
// and the script writes `null` for unknown values. Keys are decoded with
// `LSSJSON.decoder()` (`.convertFromSnakeCase`), so `ip_address` → `ipAddress`
// and `is_vm` → `isVm`; property names below must keep that spelling.
// Envelope fields (`status`, `success`, `error`, `warnings`, `skip_*`) live in
// `TaskEnvelope` and are deliberately not redeclared here.

// MARK: - Task 1 — Interface Network Info

/// `interface-network-info.json` (research 03 §1), written by `write_interface_info_json`.
public struct InterfaceInfoPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.interfaceInfo]

    public var interface: String?
    public var ipAddress: String?
    /// Dotted subnet mask, e.g. `255.255.255.0`.
    public var subnet: String?
    /// Network range in CIDR notation, e.g. `10.1.1.0/24`.
    public var network: String?
    public var gateway: String?
    public var macAddress: String?
    public var isVm: Bool?
    /// Hypervisor name; `null` on physical hosts (the script maps `"none"` to null).
    public var vmPlatform: String?

    /// Prefix length parsed from `network` (`"10.1.1.0/24"` → 24).
    public var prefixLength: Int? {
        guard let network, let slash = network.lastIndex(of: "/") else { return nil }
        return Int(network[network.index(after: slash)...])
    }
}

// MARK: - Task 2 — Internet Speed Test

/// `internet-speed-test.json` (research 03 §2), written by `write_speed_test_json`.
/// `servers` always has exactly one element in the current writer; `isp_name`
/// is missing in runs before June 2026.
public struct SpeedTestPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.speedTest]

    public struct Server: Decodable, Sendable, Hashable {
        /// `"unknown"` when the lookup failed.
        public var publicIp: String?
        public var ispName: String?
        public var testServer: String?
        /// Always `""` in current output.
        public var location: String?
        @Lenient public var pingMs: Double?
        @Lenient public var downloadMbps: Double?
        @Lenient public var uploadMbps: Double?
        /// Always `""` in current output.
        public var timestamp: String?
    }

    /// 1 on success, 0 on failure.
    @LenientInt public var speedTestsFound: Int?
    public var servers: [Server]?
    public var methodology: String?

    /// The single measurement the script records.
    public var server: Server? { servers?.first }
}

// MARK: - Task 3 — Gateway Details

/// `gateway-scan.json` (research 03 §3), written by `write_gateway_scan_json`.
/// A skipped scan (public gateway) keeps `gateway_ip` and an empty `open_ports`.
public struct GatewayScanPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.gatewayDetails]

    public var gatewayIp: String?
    public var openPorts: [Int]?
    /// `"All TCP ports (1-65535)"`.
    public var scanScope: String?
}

// MARK: - Task 4 — DHCP Network Scan

/// `dhcp-scan.json` (research 03 §4), written by `dhcp_network_scan` /
/// `write_dhcp_failure_json`. Failure files contain every key with zero counts.
/// Engine v1.2.252 adds the probe MAC, the interface's own system lease, the
/// offered options per server, the verbose tcpdump summary (`reply_sources_seen`,
/// `relay_agents_seen`, `passive_servers_seen`, `capture_message_types`) and the
/// evidence-based `rogue_reasons`; every one of them is optional.
public struct DHCPScanPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.dhcpScan]

    public struct Server: Decodable, Sendable, Hashable {
        public var ip: String?
        public var openPorts: [Int]?
        @LenientInt public var offersObserved: Int?
        @LenientInt public var rawOffersObserved: Int?
        /// `gateway`, `dhcp-service-host`, `directory-infrastructure`,
        /// `network-infrastructure`, `windows-infrastructure` or `unknown`.
        /// Informational since v1.2.252 (no longer a rogue signal).
        public var classification: String?
        public var suspectedRogue: Bool?
        /// v1.2.252: `multiple_server_identifiers`, `differs_from_system_lease`,
        /// `offered_router_not_on_subnet`, `server_outside_subnet_without_relay`.
        /// `suspectedRogue` is true exactly when this is non-empty.
        public var rogueReasons: [String]?
        /// v1.2.252: options from the offer (first non-empty value seen).
        public var offeredRouter: String?
        public var offeredSubnetMask: String?
        public var offeredDns: [String]?
        public var offeredDomain: String?
        @LenientInt public var leaseTimeSeconds: Int?
        /// v1.2.252: sender MAC of the reply whose source IP equals `ip` (tcpdump `-e`).
        public var responderMac: String?
        /// v1.2.252: replies whose message type was present and not DHCPOFFER.
        @LenientInt public var nonOfferReplies: Int?

        /// Human-readable rogue reasons, in the engine's order.
        public var rogueReasonLabels: [String] {
            (rogueReasons ?? []).map(DHCPScanPayload.rogueReasonLabel)
        }
    }

    public struct RawAttempt: Decodable, Sendable, Hashable {
        @LenientInt public var attempt: Int?
        /// nmap `broadcast-dhcp-discover` output for this attempt.
        public var outputExcerpt: String?
    }

    /// v1.2.252 `system_lease`: the lease the audited interface itself holds
    /// (macOS `ipconfig getpacket`, Linux nmcli / systemd-networkd / dhclient).
    /// The key is `null` for a static or unknown address.
    public struct SystemLease: Decodable, Sendable, Hashable {
        public var server: String?
        public var assignedIp: String?
        public var router: String?
        public var dns: [String]?
        public var domain: String?
        @LenientInt public var leaseTimeSeconds: Int?
        /// ISO-8601 when the lease was obtained, when the platform reports it.
        public var obtainedAt: String?
        /// `ipconfig`, `nmcli`, `systemd-networkd` or `dhclient`.
        public var source: String?
    }

    /// v1.2.252 `reply_sources_seen[]`: a sender of a frame from UDP port 67.
    public struct ReplySource: Decodable, Sendable, Hashable {
        public var ip: String?
        public var mac: String?
    }

    @LenientInt public var dhcpRespondersObserved: Int?
    @LenientInt public var discoveryAttempts: Int?
    /// Offers deduplicated by server identifier + offered IP.
    @LenientInt public var offersObserved: Int?
    @LenientInt public var rawOffersObserved: Int?
    /// Pre-v1.2.252 name for the port-67 senders; since v1.2.252 an alias of
    /// `relay_agents_seen` kept for one release. Prefer `replySources` / `relayAgents`.
    public var relaySourcesSeen: [String]?
    public var tcpdumpCaptureUsed: Bool?
    public var rogueDhcpSuspected: Bool?
    public var suspectedRogueServers: [String]?
    public var discoveryNote: String?
    public var rawAttempts: [RawAttempt]?
    public var servers: [Server]?
    // v1.2.252
    /// Discovery attempts that errored (nmap stderr / `ERROR:` lines).
    @LenientInt public var attemptsFailed: Int?
    /// Client hardware address used by the nmap probe; `null` when nmap's default was used.
    public var probeMac: String?
    /// `interface` or `nmap-default`.
    public var probeMacSource: String?
    public var systemLease: SystemLease?
    /// Union of every `offered_dns`.
    public var dnsServersOffered: [String]?
    public var replySourcesSeen: [ReplySource]?
    /// Real relay agents: non-zero `Gateway-IP` values and port-67 senders that are not a Server-ID.
    public var relayAgentsSeen: [String]?
    /// Server identifiers seen in any Offer/ACK on the wire, including ones that did not answer our probe.
    public var passiveServersSeen: [String]?
    /// `{Discover: n, Offer: n, Request: n, ACK: n, NAK: n}` from the tcpdump capture.
    public var captureMessageTypes: [String: Int]?

    /// Reply sources regardless of engine version: `reply_sources_seen` when present,
    /// else the legacy `relay_sources_seen` (which listed the same port-67 senders).
    public var replySources: [ReplySource] {
        if let replySourcesSeen { return replySourcesSeen }
        if relayAgentsSeen == nil, let relaySourcesSeen {
            return relaySourcesSeen.map { ReplySource(ip: $0, mac: nil) }
        }
        return []
    }

    /// Relay agents; nil when the engine did not record them (pre-v1.2.252 files).
    public var relayAgents: [String]? { relayAgentsSeen }

    /// Human label for a `rogue_reasons` token (unknown tokens are de-underscored).
    public static func rogueReasonLabel(_ token: String) -> String {
        switch token {
        case "multiple_server_identifiers": "More than one DHCP server identifier was seen"
        case "differs_from_system_lease": "Differs from the server that issued this interface's lease"
        case "offered_router_not_on_subnet": "Offered router is not on the interface's subnet"
        case "server_outside_subnet_without_relay": "Server is outside the subnet and no relay agent was seen"
        default: token.replacingOccurrences(of: "_", with: " ")
        }
    }
}

// MARK: - Task 5 — DHCP Response Time

/// `dhcp-response-time.json` (research 03 §5), written by `dhcp_response_time`.
/// `response_times_ms` holds one entry per probe with `null` for a lost probe;
/// `packet_loss_percent` is a float on success and the integer `100` on failure.
public struct DHCPResponseTimePayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.dhcpResponseTime]

    /// Present in runs from June 2026 on; every numeric field is `null` when
    /// the subnet is larger than /22 (see `note`).
    public struct SubnetUtilization: Decodable, Sendable, Hashable {
        @LenientInt public var usableHosts: Int?
        @LenientInt public var liveHosts: Int?
        @Lenient public var utilizationPercent: Double?
        public var highUtilization: Bool?
        public var note: String?
    }

    public struct Indicators: Decodable, Sendable, Hashable {
        public var slowResponse: Bool?
        public var highLoss: Bool?
        /// Missing in runs before June 2026.
        public var highUtilization: Bool?
        /// v1.2.252: Task 4 saw offers on this interface but this probe received none
        /// (a probe or receive-path problem, not a DHCP outage).
        public var probeInconsistent: Bool?
        /// v1.2.252: a responder answered the probe that discovery (Task 4) never saw.
        public var serverMismatch: Bool?
    }

    /// v1.2.252 `servers_seen[ip]`: offers and latency per responding server.
    public struct ServerStats: Decodable, Sendable, Hashable {
        @LenientInt public var offers: Int?
        @Lenient public var minMs: Double?
        @Lenient public var avgMs: Double?
        @Lenient public var maxMs: Double?
    }

    /// One responder of `servers_seen`, keyed by IP (derived, not decoded).
    public struct ServerSeen: Sendable, Hashable, Identifiable {
        public let ip: String
        public let stats: ServerStats

        public var id: String { ip }
    }

    /// One probe of `response_times_ms`, numbered from 1 (derived, not decoded).
    public struct ProbeSample: Sendable, Hashable, Identifiable {
        /// 1-based probe number.
        public let id: Int
        public let responseMs: Double?

        public var isLost: Bool { responseMs == nil }
    }

    public var methodology: String?
    public var interface: String?
    public var isWifi: Bool?
    @LenientInt public var probeCount: Int?
    @LenientInt public var respondedCount: Int?
    @LenientArray public var responseTimesMs: [Double?]?
    @Lenient public var minMs: Double?
    @Lenient public var avgMs: Double?
    @Lenient public var maxMs: Double?
    /// Float on success, `100` on a pre-v1.2.252 failure, `null` on a v1.2.252 failure.
    @Lenient public var packetLossPercent: Double?
    /// The server with the most offers (v1.2.252: ties → first seen).
    public var serverIp: String?
    public var subnetUtilization: SubnetUtilization?
    public var indicators: Indicators?
    // v1.2.252
    public var serversSeen: [String: ServerStats]?
    public var multipleResponders: Bool?
    public var offeredRouter: String?
    public var offeredDns: [String]?
    public var offeredDomain: String?
    @LenientInt public var leaseTimeSeconds: Int?
    /// `bpf` (scapy sniffer) or `socket` (stdlib fallback).
    public var receiveMethod: String?
    /// `layer2` (scapy `sendp`) or `socket` (DGRAM fallback).
    public var sendMethod: String?
    public var probeMac: String?
    /// DHCP option codes carried by the Discover, e.g. `"53,55,57,61,12"`.
    public var probeOptions: String?
    @Lenient public var intervalSeconds: Double?
    /// Responders in `servers_seen` that Task 4 did not list.
    public var unexpectedServers: [String]?

    /// `response_times_ms` as numbered samples, in probe order.
    public var probes: [ProbeSample] {
        (responseTimesMs ?? []).enumerated().map { ProbeSample(id: $0.offset + 1, responseMs: $0.element) }
    }

    /// `servers_seen` as rows, most offers first (ties by IP).
    public var serversSeenRows: [ServerSeen] {
        (serversSeen ?? [:])
            .map { ServerSeen(ip: $0.key, stats: $0.value) }
            .sorted { lhs, rhs in
                let l = lhs.stats.offers ?? 0, r = rhs.stats.offers ?? 0
                return l != r ? l > r : lhs.ip < rhs.ip
            }
    }

    /// `receive_method` / `send_method` as one label, nil for pre-v1.2.252 files.
    public var probeMethodDescription: String? {
        guard receiveMethod != nil || sendMethod != nil else { return nil }
        return "receive \(receiveMethod ?? "—"), send \(sendMethod ?? "—")"
    }
}

// MARK: - Tasks 6–9 — DNS / LDAP-AD / SMB-NFS / Printer network scans

/// `dns-scan.json`, `ldap-ad-scan.json`, `smb-nfs-scan.json` and
/// `print-server-scan.json` (research 03 §6–9), written by `scan_servers_by_ports`.
/// Task 6 adds `resolution_test` / `ptr_hostname` / `gateway_ptr` per server
/// (`enrich_dns_resolution`, current code only); Task 8 adds
/// `smb_signing_required` for hosts with port 445 that answered the probe.
public struct ServiceScanPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.dnsScan, .ldapScan, .smbNfsScan, .printServerScan]

    /// Recursion as the engine reports it since v1.2.252 (`recursion`), derived from
    /// the boolean `open_resolver` for older files.
    public enum Recursion: String, Sendable, Hashable {
        case enabled, disabled, unknown

        public var label: String {
            switch self {
            case .enabled: "Enabled"
            case .disabled: "Disabled"
            case .unknown: "Unknown"
            }
        }
    }

    public struct ResolutionTest: Decodable, Sendable, Hashable {
        /// v1.2.252 `internal_test`: the site's own domain (from the DHCP offer or
        /// system lease) resolved through this server, plus the AD SRV record.
        public struct InternalTest: Decodable, Sendable, Hashable {
            public var domain: String?
            public var resolved: Bool?
            public var srvFound: Bool?
        }

        /// `"google.com"` (v1.2.252 also queries microsoft.com; `resolved` is true when either answered).
        public var domain: String?
        public var resolved: Bool?
        @Lenient public var responseMs: Double?
        public var resolvedIps: [String]?
        /// True when recursion is enabled (kept for compatibility; see `recursionState`).
        public var openResolver: Bool?
        /// An external name resolved to a private address (DNS filtering or rebinding).
        public var rebindingRisk: Bool?
        // v1.2.252
        @LenientInt public var attempts: Int?
        /// `NOERROR`, `SERVFAIL`, `NXDOMAIN`, `REFUSED`, `other` or `timeout`.
        public var rcode: String?
        /// Recursion Available bit of the reply; `null` on timeout.
        public var ra: Bool?
        /// `enabled`, `disabled` or `unknown` (open string; see `recursionState`).
        public var recursion: String?
        /// Same meaning as `rebindingRisk` under the v1.2.252 label.
        public var externalPrivateAnswer: Bool?
        public var internalTest: InternalTest?

        /// Tri-state recursion from `recursion`, else from `open_resolver`, else unknown.
        public var recursionState: Recursion {
            if let recursion, let known = Recursion(rawValue: recursion.lowercased()) { return known }
            if let openResolver { return openResolver ? .enabled : .disabled }
            return .unknown
        }

        /// Either flag: the external name came back with a private address.
        public var answeredWithPrivateAddress: Bool? {
            guard externalPrivateAnswer != nil || rebindingRisk != nil else { return nil }
            return externalPrivateAnswer == true || rebindingRisk == true
        }
    }

    /// v1.2.252 `transport`: port-53 state per protocol from the nmap sweep.
    public struct Transport: Decodable, Sendable, Hashable {
        /// `open`, `closed` or `unknown`.
        public var tcp: String?
        /// `open`, `open|filtered`, `closed` or `unknown`.
        public var udp: String?
    }

    public struct Server: Decodable, Sendable, Hashable {
        public var ip: String?
        public var openPorts: [Int]?
        /// Labels from `label_port_service`: `dns`, `kerberos`, `ldap`, `ldaps`,
        /// `ldap-global-catalog`, `rpcbind`, `smb-netbios`, `smb`, `nfs`,
        /// `printer-lpd`, `printer-ipp`, `printer-jetdirect`, `port-<n>`.
        public var detectedServices: [String]?
        /// Task 8 only; absent when the host did not answer `smb2-security-mode`.
        public var smbSigningRequired: Bool?
        /// Task 6 only. v1.2.252 writes `null` for a server the probe could not test.
        public var resolutionTest: ResolutionTest?
        /// Task 6 only.
        public var ptrHostname: String?
        /// Task 6 only.
        public var gatewayPtr: String?
        // Task 6, v1.2.252
        /// `subnet-scan`, `configured`, `dhcp-offer`, `system-lease`.
        public var sources: [String]?
        public var onSubnet: Bool?
        public var transport: Transport?

        /// Human labels for `sources` (`dhcp-offer` → `DHCP offer`).
        public var sourceLabels: [String] {
            (sources ?? []).map(ServiceScanPayload.sourceLabel)
        }
    }

    public var network: String?
    /// Comma-separated port list as written by the script, e.g. `"88,389,636,3268,3269"`.
    public var scanPorts: String?
    public var servers: [Server]?
    // Task 6, v1.2.252
    /// The range actually swept when the interface network was wider than the cap (/22).
    public var scannedRange: String?
    public var rangeTruncated: Bool?

    /// `scanPorts` parsed into integers.
    public var scanPortList: [Int] {
        (scanPorts ?? "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Human label for a Task 6 `sources` token.
    public static func sourceLabel(_ token: String) -> String {
        switch token {
        case "subnet-scan": "Subnet scan"
        case "configured": "Configured resolver"
        case "dhcp-offer": "DHCP offer"
        case "system-lease": "System lease"
        default: token.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        }
    }
}

// MARK: - Tasks 10 and 14 — Gateway / Custom Target Stress Test

/// `gateway-stress-test-device-N.json` (task 10) and
/// `custom-target-stress-test-device-N.json` (task 14), written by
/// `run_stress_test_for_target` (research 03 §10). The target key differs:
/// task 10 writes `gateway`, task 14 writes `target_ip` — use `target`.
/// Failure files hold only the envelope plus `function`, the target key,
/// `hostname` and `interface`; unparsed metrics are `0`, never `null`.
public struct StressTestPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.gatewayStress, .customStress]

    /// Per-stage outcome: `ok`, `failed` or (ramping only) `partial`. Open strings.
    public struct StageStatus: Decodable, Sendable, Hashable {
        public var baseline: String?
        public var jitter: String?
        public var largePacket: String?
        public var ramping: String?
        public var sustained: String?
        public var recovery: String?
    }

    /// Metrics of one measured stage. Each stage writes a subset:
    /// baseline = avg/max/stddev, jitter = stddev/max/loss,
    /// large packet and sustained = avg/max/loss, recovery = avg/returnedToBaseline.
    public struct Stage: Decodable, Sendable, Hashable {
        @Lenient public var avgLatencyMs: Double?
        @Lenient public var maxLatencyMs: Double?
        @Lenient public var stddevMs: Double?
        @Lenient public var packetLossPercent: Double?
        public var returnedToBaseline: Bool?
    }

    /// One packet size of the ramping stage (64, 256, 512, 1024, 1400 bytes).
    public struct RampingStep: Decodable, Sendable, Hashable {
        @LenientInt public var packetSize: Int?
        @Lenient public var avgLatencyMs: Double?
        @Lenient public var maxLatencyMs: Double?
        @Lenient public var packetLossPercent: Double?
    }

    public struct Indicators: Decodable, Sendable, Hashable {
        public var highJitter: Bool?
        public var latencyUnderLoad: Bool?
        public var packetLoss: Bool?
        public var slowRecovery: Bool?
    }

    /// The six stages in test order, each with its status and metrics (derived).
    public struct StageSummary: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable, Hashable, CaseIterable {
            case baseline, jitter, largePacket, ramping, sustained, recovery

            public var title: String {
                switch self {
                case .baseline: "Baseline"
                case .jitter: "Jitter"
                case .largePacket: "Large packet"
                case .ramping: "Ramping"
                case .sustained: "Sustained load"
                case .recovery: "Recovery"
                }
            }
        }

        public let kind: Kind
        public let status: String?
        /// `nil` for the ramping stage, whose metrics are per packet size (`rampingTest`).
        public let metrics: Stage?

        public var id: Kind { kind }
        public var title: String { kind.title }
    }

    /// `gateway_stress_test` or `custom_target_stress_test`.
    public var function: String?
    /// Task 10 target key.
    public var gateway: String?
    /// Task 14 target key.
    public var targetIp: String?
    /// `"unknown"` when reverse lookup failed.
    public var hostname: String?
    public var interface: String?
    public var completedWithWarnings: Bool?
    /// Same text as `warnings[0]` when a stage failed.
    public var warning: String?
    public var stageStatus: StageStatus?
    public var baseline: Stage?
    public var jitterTest: Stage?
    public var largePacketTest: Stage?
    public var rampingTest: [RampingStep]?
    public var sustainedTest: Stage?
    public var recovery: Stage?
    public var indicators: Indicators?
    public var methodology: String?

    /// The tested address regardless of which key the task wrote.
    public var target: String? { gateway ?? targetIp }

    /// False for failure-only files (the test aborted before any stage was summarised).
    public var hasMeasurements: Bool {
        baseline != nil || jitterTest != nil || largePacketTest != nil
            || !(rampingTest ?? []).isEmpty || sustainedTest != nil || recovery != nil
    }

    /// All six stages in test order with their status and metrics.
    public var stages: [StageSummary] {
        [
            StageSummary(kind: .baseline, status: stageStatus?.baseline, metrics: baseline),
            StageSummary(kind: .jitter, status: stageStatus?.jitter, metrics: jitterTest),
            StageSummary(kind: .largePacket, status: stageStatus?.largePacket, metrics: largePacketTest),
            StageSummary(kind: .ramping, status: stageStatus?.ramping, metrics: nil),
            StageSummary(kind: .sustained, status: stageStatus?.sustained, metrics: sustainedTest),
            StageSummary(kind: .recovery, status: stageStatus?.recovery, metrics: recovery),
        ]
    }
}

// MARK: - Task 11 — VLAN / Trunk Detection

/// `vlan-trunk-scan.json` (research 03 §11), written by `vlan_trunk_scan`.
/// The `NO_INTERFACE` failure writes only the envelope.
public struct VLANTrunkPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.vlanTrunk]

    public struct CDPNeighbour: Decodable, Sendable, Hashable {
        public var deviceId: String?
        public var platform: String?
        public var portId: String?
        @LenientInt public var nativeVlan: Int?
        public var vtpDomain: String?
        /// `""`, `"full"` or `"half"`.
        public var duplex: String?
    }

    public struct LLDPNeighbour: Decodable, Sendable, Hashable {
        public var systemName: String?
        public var chassisId: String?
        public var portId: String?
        public var systemDescription: String?
    }

    /// Always `{attempted: false, vulnerable: null}` in the current script.
    public struct DoubleTagProbe: Decodable, Sendable, Hashable {
        public var attempted: Bool?
        public var vulnerable: Bool?
    }

    public struct Indicators: Decodable, Sendable, Hashable {
        public var trunkPortSuspected: Bool?
        public var cdpExposed: Bool?
        public var multipleVlansVisible: Bool?
    }

    public var interface: String?
    public var taggedFramesObserved: Bool?
    public var observedVlanIds: [Int]?
    public var cdpNeighbours: [CDPNeighbour]?
    public var lldpNeighbours: [LLDPNeighbour]?
    public var doubleTagProbe: DoubleTagProbe?
    public var indicators: Indicators?
}

// MARK: - Task 12 — Duplicate IP Detection

/// `duplicate-ip-scan.json` (research 03 §12), written by `duplicate_ip_detection`.
/// Old runs may report `total_hosts_seen: 0` with `status: success`.
public struct DuplicateIPPayload: TaskPayload, Hashable {
    public static let taskIDs: [TaskID] = [.duplicateIP]

    public struct Duplicate: Decodable, Sendable, Hashable {
        public var ip: String?
        public var macs: [String]?
        /// Parallel to `macs`.
        public var vendors: [String]?
    }

    public var interface: String?
    public var network: String?
    @LenientInt public var totalHostsSeen: Int?
    @LenientInt public var duplicateCount: Int?
    public var duplicates: [Duplicate]?

    public var hasDuplicates: Bool {
        (duplicateCount ?? 0) > 0 || !(duplicates ?? []).isEmpty
    }
}

// MARK: - Registry entry point

/// Decodes the envelope and payload of a core-audit task file.
///
/// Returns `nil` for tasks this file does not own (13, 15–20). Task 14 (Custom
/// Target Stress Test) IS handled here because it shares `StressTestPayload`
/// with task 10; the registry calls this function before
/// `decodeSpecialistPayload`, so the specialist decoder never sees task 14.
public func decodeCoreAuditPayload(task: TaskID, data: Data) throws -> (TaskEnvelope, any TaskPayload)? {
    switch task {
    case .interfaceInfo:
        return try decodeTaskResult(InterfaceInfoPayload.self, from: data)
    case .speedTest:
        return try decodeTaskResult(SpeedTestPayload.self, from: data)
    case .gatewayDetails:
        return try decodeTaskResult(GatewayScanPayload.self, from: data)
    case .dhcpScan:
        return try decodeTaskResult(DHCPScanPayload.self, from: data)
    case .dhcpResponseTime:
        return try decodeTaskResult(DHCPResponseTimePayload.self, from: data)
    case .dnsScan, .ldapScan, .smbNfsScan, .printServerScan:
        return try decodeTaskResult(ServiceScanPayload.self, from: data)
    case .gatewayStress, .customStress:
        return try decodeTaskResult(StressTestPayload.self, from: data)
    case .vlanTrunk:
        return try decodeTaskResult(VLANTrunkPayload.self, from: data)
    case .duplicateIP:
        return try decodeTaskResult(DuplicateIPPayload.self, from: data)
    case .customPortScan, .customIdentity, .customDNS,
         .wirelessSurvey, .unifiDiscovery, .unifiAdoption, .findByMAC:
        return nil
    }
}

private func decodeTaskResult<Payload: TaskPayload>(_: Payload.Type, from data: Data) throws -> (TaskEnvelope, any TaskPayload) {
    let result = try LSSJSON.decode(TaskResult<Payload>.self, from: data)
    return (result.envelope, result.payload)
}
