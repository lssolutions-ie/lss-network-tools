import Foundation
import Testing
@testable import LSSCore

// Inline fixtures adapted from the real runs under
// /usr/local/share/lss-network-tools/output (public addresses replaced with
// 203.0.113.x, client names with "Client A") plus synthetic failure shapes
// mirrored from the jq writers in lss-network-tools.sh. Everything goes
// through `decodeCoreAuditPayload`, the entry point the registry uses.

/// Decodes through the registry entry point and casts to the expected payload.
private func decodeCore<Payload: TaskPayload>(
    _: Payload.Type,
    task: TaskID,
    _ json: String
) throws -> (envelope: TaskEnvelope, payload: Payload) {
    let result = try #require(try decodeCoreAuditPayload(task: task, data: Data(json.utf8)))
    let payload = try #require(result.1 as? Payload, "expected \(Payload.self), got \(type(of: result.1))")
    return (result.0, payload)
}

@Suite("Core audit payloads (tasks 1–12 and 14)")
struct CoreAuditPayloadTests {

    // MARK: - Task 1 — Interface Network Info

    @Test("Task 1 success decodes every field")
    func interfaceInfo() throws {
        let json = #"""
        {
          "status": "success", "success": true, "error": null, "warnings": [],
          "interface": "en0", "ip_address": "10.1.1.172", "subnet": "255.255.255.0",
          "network": "10.1.1.0/24", "gateway": "10.1.1.254", "mac_address": "46:37:42:69:cf:fe",
          "is_vm": false, "vm_platform": null
        }
        """#
        let (envelope, payload) = try decodeCore(InterfaceInfoPayload.self, task: .interfaceInfo, json)
        #expect(envelope.effectiveStatus == .success)
        #expect(envelope.success == true)
        #expect(envelope.error == nil)
        #expect(envelope.warnings.isEmpty)
        #expect(payload.interface == "en0")
        #expect(payload.ipAddress == "10.1.1.172")
        #expect(payload.subnet == "255.255.255.0")
        #expect(payload.network == "10.1.1.0/24")
        #expect(payload.prefixLength == 24)
        #expect(payload.gateway == "10.1.1.254")
        #expect(payload.macAddress == "46:37:42:69:cf:fe")
        #expect(payload.isVm == false)
        #expect(payload.vmPlatform == nil)
    }

    @Test("Task 1 failure keeps the nulls and carries the error")
    func interfaceInfoFailure() throws {
        let json = #"""
        {
          "status": "failed", "success": false,
          "error": {"code": "no_ipv4_or_subnet_detected", "message": "No IPv4 address or subnet mask detected on en5."},
          "warnings": [], "interface": "en5", "ip_address": null, "subnet": null, "network": null,
          "gateway": null, "mac_address": "3c:18:a0:d5:ad:4f", "is_vm": true, "vm_platform": "Parallels"
        }
        """#
        let (envelope, payload) = try decodeCore(InterfaceInfoPayload.self, task: .interfaceInfo, json)
        #expect(envelope.effectiveStatus == .failed)
        #expect(envelope.effectiveStatus.isFailure)
        #expect(envelope.error?.code == "no_ipv4_or_subnet_detected")
        #expect(payload.ipAddress == nil)
        #expect(payload.prefixLength == nil)
        #expect(payload.isVm == true)
        #expect(payload.vmPlatform == "Parallels")
    }

    // MARK: - Task 2 — Internet Speed Test

    @Test("Task 2 June 2026 shape with isp_name")
    func speedTestWithISP() throws {
        let json = #"""
        {
          "status": "success", "success": true, "error": null, "warnings": [],
          "speed_tests_found": 1,
          "servers": [
            {"public_ip": "203.0.113.5", "isp_name": "HEAnet", "test_server": "Sky (Dublin)", "location": "",
             "ping_ms": 10.886, "download_mbps": 41.54, "upload_mbps": 35.76, "timestamp": ""}
          ],
          "methodology": "Single point-in-time measurement using speedtest-cli."
        }
        """#
        let (envelope, payload) = try decodeCore(SpeedTestPayload.self, task: .speedTest, json)
        #expect(envelope.effectiveStatus == .success)
        #expect(payload.speedTestsFound == 1)
        #expect(payload.servers?.count == 1)
        let server = try #require(payload.server)
        #expect(server.publicIp == "203.0.113.5")
        #expect(server.ispName == "HEAnet")
        #expect(server.testServer == "Sky (Dublin)")
        #expect(server.pingMs == 10.886)
        #expect(server.downloadMbps == 41.54)
        #expect(server.uploadMbps == 35.76)
        #expect(Sentinel.value(server.location) == nil, "empty location is a sentinel")
        #expect(Sentinel.value(server.timestamp) == nil)
    }

    @Test("Task 2 pre-June shape has no isp_name")
    func speedTestWithoutISP() throws {
        let json = #"""
        {
          "status": "success", "success": true, "error": null, "warnings": [],
          "speed_tests_found": 1,
          "servers": [
            {"public_ip": "203.0.113.123", "test_server": "fdcservers.net (Dublin)", "location": "",
             "ping_ms": 6.108, "download_mbps": 91.10, "upload_mbps": 89.45, "timestamp": ""}
          ],
          "methodology": "Single point-in-time measurement using speedtest-cli."
        }
        """#
        let (_, payload) = try decodeCore(SpeedTestPayload.self, task: .speedTest, json)
        let server = try #require(payload.server)
        #expect(server.ispName == nil)
        #expect(server.downloadMbps == 91.10)
        #expect(server.pingMs == 6.108)
    }

    @Test("Task 2 failure writes null metrics and the unknown sentinel")
    func speedTestFailure() throws {
        let json = #"""
        {
          "status": "failed", "success": false,
          "error": {"code": "speedtest_timeout", "message": "speedtest-cli did not finish within 90 seconds."},
          "warnings": [], "speed_tests_found": 0,
          "servers": [
            {"public_ip": "unknown", "isp_name": null, "test_server": "", "location": "",
             "ping_ms": null, "download_mbps": null, "upload_mbps": null, "timestamp": ""}
          ],
          "methodology": "Single point-in-time measurement using speedtest-cli."
        }
        """#
        let (envelope, payload) = try decodeCore(SpeedTestPayload.self, task: .speedTest, json)
        #expect(envelope.error?.code == "speedtest_timeout")
        #expect(payload.speedTestsFound == 0)
        let server = try #require(payload.server)
        #expect(server.pingMs == nil)
        #expect(server.downloadMbps == nil)
        #expect(Sentinel.value(server.publicIp) == nil)
    }

    @Test("Task 2 legacy raw speedtest-cli shape decodes without throwing and is ignored")
    func speedTestLegacyShapeIgnored() throws {
        let json = #"""
        {
          "client": {"ip": "203.0.113.9", "isp": "Example ISP"},
          "server": {"name": "Dublin", "country": "Ireland"},
          "ping": 12.3, "download": 84450000.0, "upload": 18880000.0
        }
        """#
        let (envelope, payload) = try decodeCore(SpeedTestPayload.self, task: .speedTest, json)
        #expect(envelope.status == nil)
        #expect(envelope.effectiveStatus == .other("unknown"))
        #expect(payload.servers == nil)
        #expect(payload.server == nil)
        #expect(payload.speedTestsFound == nil)
    }

    // MARK: - Task 3 — Gateway Details

    @Test("Task 3 success lists the open ports")
    func gatewayScan() throws {
        let json = #"""
        {
          "status": "success", "success": true, "error": null, "warnings": [],
          "gateway_ip": "10.1.1.254", "open_ports": [22, 53, 199, 20201, 20202],
          "scan_scope": "All TCP ports (1-65535)"
        }
        """#
        let (_, payload) = try decodeCore(GatewayScanPayload.self, task: .gatewayDetails, json)
        #expect(payload.gatewayIp == "10.1.1.254")
        #expect(payload.openPorts == [22, 53, 199, 20201, 20202])
        #expect(payload.scanScope == "All TCP ports (1-65535)")
    }

    @Test("Task 3 skipped: success false, error null, skip fields present")
    func gatewayScanSkipped() throws {
        let json = #"""
        {
          "status": "skipped", "success": false,
          "skip_reason": "gateway_public_ip",
          "skip_message": "Gateway IP 203.0.113.1 is publicly routable. Port scanning has been skipped.",
          "error": null, "warnings": [],
          "gateway_ip": "203.0.113.1", "open_ports": [], "scan_scope": "All TCP ports (1-65535)"
        }
        """#
        let (envelope, payload) = try decodeCore(GatewayScanPayload.self, task: .gatewayDetails, json)
        #expect(envelope.effectiveStatus == .skipped)
        #expect(envelope.effectiveStatus.isFailure == false, "skipped is not a failure")
        #expect(envelope.success == false)
        #expect(envelope.error == nil)
        #expect(envelope.skipReason == "gateway_public_ip")
        #expect(envelope.skipMessage?.hasPrefix("Gateway IP 203.0.113.1") == true)
        #expect(payload.gatewayIp == "203.0.113.1")
        #expect(payload.openPorts?.isEmpty == true)
    }

    @Test("Task 3 completed_with_warnings with no open ports")
    func gatewayScanNoPorts() throws {
        let json = #"""
        {
          "status": "completed_with_warnings", "success": true, "error": null,
          "warnings": ["The gateway responded, but no open TCP ports were detected during the scan."],
          "gateway_ip": "10.1.40.1", "open_ports": [], "scan_scope": "All TCP ports (1-65535)"
        }
        """#
        let (envelope, payload) = try decodeCore(GatewayScanPayload.self, task: .gatewayDetails, json)
        #expect(envelope.effectiveStatus == .completedWithWarnings)
        #expect(envelope.warnings.count == 1)
        #expect(payload.openPorts == [])
    }

    // MARK: - Task 4 — DHCP Network Scan

    @Test("Task 4 success with responder, relay source and raw attempts")
    func dhcpScan() throws {
        let json = #"""
        {
          "status": "success", "success": true, "error": null, "warnings": [],
          "dhcp_responders_observed": 1, "discovery_attempts": 5, "offers_observed": 1, "raw_offers_observed": 5,
          "relay_sources_seen": ["10.1.1.1"], "tcpdump_capture_used": true,
          "rogue_dhcp_suspected": false, "suspected_rogue_servers": [],
          "discovery_note": "DHCP detection uses repeated broadcast discovery attempts.",
          "raw_attempts": [
            {"attempt": 1, "output_excerpt": "Starting Nmap 7.98 ( https://nmap.org ) at 2026-03-31 13:14 +0100\nPre-scan script results:\n| broadcast-dhcp-discover: \n|     IP Offered: 10.1.1.188\n|     Server Identifier: 10.1.1.1\n|_    Domain Name: clienta.local\\x00"},
            {"attempt": 2, "output_excerpt": "Starting Nmap 7.98 ( https://nmap.org ) at 2026-03-31 13:14 +0100\nNmap done: 0 IP addresses (0 hosts up) scanned in 10.04 seconds"}
          ],
          "servers": [
            {"ip": "10.1.1.1", "open_ports": [53, 88, 135, 139, 389, 445, 464, 593, 636, 3268, 3269, 3389, 5357, 5985],
             "offers_observed": 1, "raw_offers_observed": 5, "classification": "directory-infrastructure", "suspected_rogue": false}
          ]
        }
        """#
        let (envelope, payload) = try decodeCore(DHCPScanPayload.self, task: .dhcpScan, json)
        #expect(envelope.effectiveStatus == .success)
        #expect(payload.dhcpRespondersObserved == 1)
        #expect(payload.discoveryAttempts == 5)
        #expect(payload.offersObserved == 1)
        #expect(payload.rawOffersObserved == 5)
        #expect(payload.relaySourcesSeen == ["10.1.1.1"])
        #expect(payload.tcpdumpCaptureUsed == true)
        #expect(payload.rogueDhcpSuspected == false)
        #expect(payload.suspectedRogueServers?.isEmpty == true)
        #expect(payload.rawAttempts?.count == 2)
        #expect(payload.rawAttempts?[0].attempt == 1)
        #expect(payload.rawAttempts?[0].outputExcerpt?.contains("\n|     IP Offered: 10.1.1.188") == true)
        let server = try #require(payload.servers?.first)
        #expect(server.ip == "10.1.1.1")
        #expect(server.openPorts?.count == 14)
        #expect(server.classification == "directory-infrastructure")
        #expect(server.suspectedRogue == false)
        #expect(server.offersObserved == 1)
        #expect(server.rawOffersObserved == 5)
    }

    @Test("Task 4 failure file has zero counts; legacy dhcp_servers_found key is ignored")
    func dhcpScanFailureAndLegacyKey() throws {
        let json = #"""
        {
          "status": "failed", "success": false,
          "error": {"code": "dhcp_privilege_required", "message": "DHCP discovery requires root privileges."},
          "warnings": [], "dhcp_responders_observed": 0, "discovery_attempts": 5, "offers_observed": 0,
          "raw_offers_observed": 0, "relay_sources_seen": [], "tcpdump_capture_used": false,
          "rogue_dhcp_suspected": false, "suspected_rogue_servers": [], "discovery_note": "",
          "raw_attempts": [], "servers": [], "dhcp_servers_found": 0
        }
        """#
        let (envelope, payload) = try decodeCore(DHCPScanPayload.self, task: .dhcpScan, json)
        #expect(envelope.error?.code == "dhcp_privilege_required")
        #expect(payload.dhcpRespondersObserved == 0)
        #expect(payload.servers?.isEmpty == true)
        #expect(payload.rawAttempts?.isEmpty == true)
        #expect(payload.tcpdumpCaptureUsed == false)
        #expect(Sentinel.value(payload.discoveryNote) == nil)
    }

    // MARK: - Task 5 — DHCP Response Time

    @Test("Task 5 partial loss: nulls inside response_times_ms, no subnet_utilization (March run)")
    func dhcpResponseTimePartialLoss() throws {
        let json = #"""
        {
          "status": "completed_with_warnings", "success": true, "error": null,
          "warnings": ["Packet loss observed: 70.0% of DHCP Discover probes received no Offer."],
          "methodology": "DHCP Discover-to-Offer latency measured using UDP broadcast probes.",
          "interface": "en8", "is_wifi": false, "probe_count": 10, "responded_count": 3,
          "response_times_ms": [2.2, null, null, null, null, null, null, 3.0, 2.8, null],
          "min_ms": 2.2, "avg_ms": 2.7, "max_ms": 3.0, "packet_loss_percent": 70.0,
          "server_ip": "203.0.113.2",
          "indicators": {"slow_response": false, "high_loss": true}
        }
        """#
        let (envelope, payload) = try decodeCore(DHCPResponseTimePayload.self, task: .dhcpResponseTime, json)
        #expect(envelope.effectiveStatus == .completedWithWarnings)
        #expect(payload.interface == "en8")
        #expect(payload.isWifi == false)
        #expect(payload.probeCount == 10)
        #expect(payload.respondedCount == 3)
        #expect(payload.responseTimesMs == [2.2, nil, nil, nil, nil, nil, nil, 3.0, 2.8, nil])
        #expect(payload.minMs == 2.2)
        #expect(payload.avgMs == 2.7)
        #expect(payload.maxMs == 3.0)
        #expect(payload.packetLossPercent == 70.0)
        #expect(payload.serverIp == "203.0.113.2")
        #expect(payload.subnetUtilization == nil)
        #expect(payload.indicators?.highLoss == true)
        #expect(payload.indicators?.slowResponse == false)
        #expect(payload.indicators?.highUtilization == nil)
        #expect(payload.probes.count == 10)
        #expect(payload.probes.filter(\.isLost).count == 7)
        #expect(payload.probes.first?.id == 1)
        #expect(payload.probes[7].responseMs == 3.0)
    }

    @Test("Task 5 every probe lost, with subnet_utilization (June run)")
    func dhcpResponseTimeAllLost() throws {
        let json = #"""
        {
          "status": "completed_with_warnings", "success": true, "error": null,
          "warnings": ["No DHCP Offer was received for any of the 10 Discover probes."],
          "methodology": "DHCP Discover-to-Offer latency measured using UDP broadcast probes.",
          "interface": "en0", "is_wifi": true, "probe_count": 10, "responded_count": 0,
          "response_times_ms": [null, null, null, null, null, null, null, null, null, null],
          "min_ms": null, "avg_ms": null, "max_ms": null, "packet_loss_percent": 100.0, "server_ip": null,
          "subnet_utilization": {"usable_hosts": 254, "live_hosts": 16, "utilization_percent": 6.3,
                                 "high_utilization": false,
                                 "note": "estimated from nmap ping scan; reflects responding hosts, not actual DHCP lease count"},
          "indicators": {"slow_response": false, "high_loss": true, "high_utilization": false}
        }
        """#
        let (_, payload) = try decodeCore(DHCPResponseTimePayload.self, task: .dhcpResponseTime, json)
        #expect(payload.isWifi == true)
        #expect(payload.respondedCount == 0)
        #expect(payload.responseTimesMs?.count == 10)
        #expect(payload.responseTimesMs?.allSatisfy { $0 == nil } == true)
        #expect(payload.avgMs == nil)
        #expect(payload.serverIp == nil)
        #expect(payload.packetLossPercent == 100)
        let utilization = try #require(payload.subnetUtilization)
        #expect(utilization.usableHosts == 254)
        #expect(utilization.liveHosts == 16)
        #expect(utilization.utilizationPercent == 6.3)
        #expect(utilization.highUtilization == false)
        #expect(utilization.note?.hasPrefix("estimated from nmap ping scan") == true)
        #expect(payload.indicators?.highUtilization == false)
        #expect(payload.probes.allSatisfy(\.isLost) == true)
    }

    @Test("Task 5 subnet_utilization with null numbers (subnet larger than /22)")
    func dhcpResponseTimeUtilizationNulls() throws {
        let json = #"""
        {
          "status": "success", "success": true, "error": null, "warnings": [],
          "interface": "en8", "is_wifi": false, "probe_count": 10, "responded_count": 10,
          "response_times_ms": [1.3, 1.4, 1.3, 1.3, 1.4, 1.4, 1.3, 1.3, 1.3, 1.3],
          "min_ms": 1.3, "avg_ms": 1.3, "max_ms": 1.4, "packet_loss_percent": 0.0, "server_ip": "172.16.3.253",
          "subnet_utilization": {"usable_hosts": null, "live_hosts": null, "utilization_percent": null,
                                 "high_utilization": false, "note": "subnet too large to scan quickly"},
          "indicators": {"slow_response": false, "high_loss": false, "high_utilization": false}
        }
        """#
        let (_, payload) = try decodeCore(DHCPResponseTimePayload.self, task: .dhcpResponseTime, json)
        let utilization = try #require(payload.subnetUtilization)
        #expect(utilization.usableHosts == nil)
        #expect(utilization.liveHosts == nil)
        #expect(utilization.utilizationPercent == nil)
        #expect(utilization.note == "subnet too large to scan quickly")
        #expect(payload.packetLossPercent == 0)
        #expect(payload.probes.filter(\.isLost).isEmpty == true)
    }

    @Test("Task 5 failure: integer packet_loss_percent, empty array, no methodology/is_wifi")
    func dhcpResponseTimeFailure() throws {
        let json = #"""
        {
          "status": "failed", "success": false,
          "error": {"code": "NO_INTERFACE", "message": "No network interface selected."},
          "warnings": [], "interface": null, "probe_count": 0, "responded_count": 0, "response_times_ms": [],
          "min_ms": null, "avg_ms": null, "max_ms": null, "packet_loss_percent": 100, "server_ip": null,
          "indicators": {"slow_response": false, "high_loss": false}
        }
        """#
        let (envelope, payload) = try decodeCore(DHCPResponseTimePayload.self, task: .dhcpResponseTime, json)
        #expect(envelope.error?.code == "NO_INTERFACE")
        #expect(payload.interface == nil)
        #expect(payload.isWifi == nil)
        #expect(payload.methodology == nil)
        #expect(payload.probeCount == 0)
        #expect(payload.responseTimesMs?.isEmpty == true)
        #expect(payload.probes.isEmpty)
        #expect(payload.packetLossPercent == 100, "integer 100 decodes as a Double")
        #expect(payload.subnetUtilization == nil)
    }

    @Test("Task 5 numbers written as strings are decoded leniently")
    func dhcpResponseTimeLenientStrings() throws {
        let json = #"""
        {
          "status": "success", "success": true, "error": null, "warnings": [],
          "interface": "en13", "probe_count": "3", "responded_count": 2,
          "response_times_ms": [1.3, "1.4", null],
          "min_ms": "1.3", "avg_ms": "1.35", "max_ms": 1.4, "packet_loss_percent": "33.3", "server_ip": "192.168.1.254",
          "indicators": {"slow_response": false, "high_loss": true}
        }
        """#
        let (_, payload) = try decodeCore(DHCPResponseTimePayload.self, task: .dhcpResponseTime, json)
        #expect(payload.probeCount == 3)
        #expect(payload.responseTimesMs == [1.3, 1.4, nil])
        #expect(payload.minMs == 1.3)
        #expect(payload.avgMs == 1.35)
        #expect(payload.packetLossPercent == 33.3)
    }

    // MARK: - Tasks 6–9 — Service scans

    @Test("Task 8 SMB signing: true, false and missing per host")
    func serviceScanSMBSigning() throws {
        let json = #"""
        {
          "status": "success", "success": true, "error": null, "warnings": [],
          "network": "10.1.1.0/24", "scan_ports": "111,139,445,2049",
          "servers": [
            {"ip": "10.1.1.1", "open_ports": [139, 445], "detected_services": ["smb-netbios", "smb"], "smb_signing_required": true},
            {"ip": "10.1.1.9", "open_ports": [111, 139, 445, 2049], "detected_services": ["rpcbind", "smb-netbios", "smb", "nfs"], "smb_signing_required": false},
            {"ip": "10.1.1.10", "open_ports": [111], "detected_services": ["rpcbind"]},
            {"ip": "10.1.1.153", "open_ports": [139, 445], "detected_services": ["smb-netbios", "smb"]}
          ]
        }
        """#
        let (_, payload) = try decodeCore(ServiceScanPayload.self, task: .smbNfsScan, json)
        #expect(payload.network == "10.1.1.0/24")
        #expect(payload.scanPorts == "111,139,445,2049")
        #expect(payload.scanPortList == [111, 139, 445, 2049])
        let servers = try #require(payload.servers)
        #expect(servers.count == 4)
        #expect(servers[0].smbSigningRequired == true)
        #expect(servers[1].smbSigningRequired == false)
        #expect(servers[1].openPorts == [111, 139, 445, 2049])
        #expect(servers[1].detectedServices == ["rpcbind", "smb-netbios", "smb", "nfs"])
        #expect(servers[2].smbSigningRequired == nil)
        #expect(servers[3].smbSigningRequired == nil, "host with 445 that did not answer the probe")
        #expect(servers.allSatisfy { $0.resolutionTest == nil } == true)
    }

    @Test("Task 6 DNS enrichment: resolution_test, ptr_hostname and null gateway_ptr")
    func serviceScanDNSEnrichment() throws {
        let json = #"""
        {
          "status": "success", "success": true, "error": null, "warnings": [],
          "network": "10.1.1.0/24", "scan_ports": "53",
          "servers": [
            {"ip": "10.1.1.1", "open_ports": [53], "detected_services": ["dns"],
             "resolution_test": {"domain": "google.com", "resolved": true, "response_ms": 12.4,
                                 "resolved_ips": ["142.250.187.206", "142.250.187.238"],
                                 "open_resolver": true, "rebinding_risk": false},
             "ptr_hostname": "dc1.clienta.local", "gateway_ptr": null},
            {"ip": "10.1.1.254", "open_ports": [53], "detected_services": ["dns"],
             "resolution_test": {"domain": "google.com", "resolved": false, "response_ms": null,
                                 "resolved_ips": [], "open_resolver": false, "rebinding_risk": false},
             "ptr_hostname": null, "gateway_ptr": null}
          ]
        }
        """#
        let (_, payload) = try decodeCore(ServiceScanPayload.self, task: .dnsScan, json)
        #expect(payload.scanPortList == [53])
        let servers = try #require(payload.servers)
        let first = try #require(servers.first?.resolutionTest)
        #expect(first.domain == "google.com")
        #expect(first.resolved == true)
        #expect(first.responseMs == 12.4)
        #expect(first.resolvedIps?.count == 2)
        #expect(first.openResolver == true)
        #expect(first.rebindingRisk == false)
        #expect(servers[0].ptrHostname == "dc1.clienta.local")
        #expect(servers[0].gatewayPtr == nil)
        #expect(servers[1].resolutionTest?.resolved == false)
        #expect(servers[1].resolutionTest?.responseMs == nil)
        #expect(servers[1].ptrHostname == nil)
    }

    @Test("Task 7 empty result is completed_with_warnings with an empty servers array")
    func serviceScanEmpty() throws {
        let json = #"""
        {
          "status": "completed_with_warnings", "success": true, "error": null,
          "warnings": ["The scan completed, but no matching hosts were found on the selected network range."],
          "network": "10.1.20.0/24", "scan_ports": "88,389,636,3268,3269", "servers": []
        }
        """#
        let (envelope, payload) = try decodeCore(ServiceScanPayload.self, task: .ldapScan, json)
        #expect(envelope.effectiveStatus == .completedWithWarnings)
        #expect(envelope.warnings.count == 1)
        #expect(payload.servers?.isEmpty == true)
        #expect(payload.scanPortList == [88, 389, 636, 3268, 3269])
    }

    @Test("Task 9 print servers carry the printer service labels")
    func serviceScanPrintServers() throws {
        let json = #"""
        {
          "status": "success", "success": true, "error": null, "warnings": [],
          "network": "172.16.0.0/22", "scan_ports": "515,631,9100",
          "servers": [
            {"ip": "172.16.0.140", "open_ports": [515, 631, 9100], "detected_services": ["printer-lpd", "printer-ipp", "printer-jetdirect"]},
            {"ip": "172.16.2.15", "open_ports": [515, 9100], "detected_services": ["printer-lpd", "printer-jetdirect"]}
          ]
        }
        """#
        let (_, payload) = try decodeCore(ServiceScanPayload.self, task: .printServerScan, json)
        #expect(payload.servers?.count == 2)
        #expect(payload.servers?[1].detectedServices == ["printer-lpd", "printer-jetdirect"])
        #expect(payload.servers?[1].openPorts == [515, 9100])
    }

    @Test("Service scan failure: network null, servers empty")
    func serviceScanFailure() throws {
        let json = #"""
        {
          "status": "failed", "success": false,
          "error": {"code": "network_range_not_detected", "message": "Unable to determine the network range for the selected interface."},
          "warnings": [], "network": null, "scan_ports": "53", "servers": []
        }
        """#
        let (envelope, payload) = try decodeCore(ServiceScanPayload.self, task: .dnsScan, json)
        #expect(envelope.error?.code == "network_range_not_detected")
        #expect(payload.network == nil)
        #expect(payload.scanPorts == "53")
        #expect(payload.servers?.isEmpty == true)
    }

    // MARK: - Tasks 10 and 14 — Stress test

    private static let stressSuccessJSON = #"""
    {
      "status": "success", "success": true, "error": null, "warnings": [],
      "function": "gateway_stress_test", "gateway": "10.1.1.254", "hostname": "unknown", "interface": "en0",
      "completed_with_warnings": false, "warning": null,
      "stage_status": {"baseline": "ok", "jitter": "ok", "large_packet": "ok", "ramping": "ok", "sustained": "ok", "recovery": "ok"},
      "baseline": {"avg_latency_ms": 1.234, "max_latency_ms": 3.456, "stddev_ms": 0.512},
      "jitter_test": {"stddev_ms": 0.734, "max_latency_ms": 6.1, "packet_loss_percent": 0},
      "large_packet_test": {"avg_latency_ms": 1.9, "max_latency_ms": 4.2, "packet_loss_percent": 0.0},
      "ramping_test": [
        {"packet_size": 64, "avg_latency_ms": 1.1, "max_latency_ms": 2.0, "packet_loss_percent": 0},
        {"packet_size": 256, "avg_latency_ms": 1.3, "max_latency_ms": 2.4, "packet_loss_percent": 0},
        {"packet_size": 512, "avg_latency_ms": 1.5, "max_latency_ms": 2.9, "packet_loss_percent": 0},
        {"packet_size": 1024, "avg_latency_ms": 1.8, "max_latency_ms": 3.3, "packet_loss_percent": 0},
        {"packet_size": 1400, "avg_latency_ms": 2.1, "max_latency_ms": 4.8, "packet_loss_percent": 5.0}
      ],
      "sustained_test": {"avg_latency_ms": 1.6, "max_latency_ms": 9.7, "packet_loss_percent": 0.5},
      "recovery": {"avg_latency_ms": 1.3, "returned_to_baseline": true},
      "indicators": {"high_jitter": false, "latency_under_load": false, "packet_loss": true, "slow_recovery": false},
      "methodology": "ICMP-based point-in-time stress test. Measures latency and packet loss under staged load; does not test throughput."
    }
    """#

    @Test("Task 10 success: gateway key, all stages, int and float packet_loss_percent")
    func stressTestGateway() throws {
        let (envelope, payload) = try decodeCore(StressTestPayload.self, task: .gatewayStress, Self.stressSuccessJSON)
        #expect(envelope.effectiveStatus == .success)
        #expect(payload.function == "gateway_stress_test")
        #expect(payload.gateway == "10.1.1.254")
        #expect(payload.targetIp == nil)
        #expect(payload.target == "10.1.1.254")
        #expect(Sentinel.value(payload.hostname) == nil)
        #expect(payload.interface == "en0")
        #expect(payload.completedWithWarnings == false)
        #expect(payload.warning == nil)
        #expect(payload.stageStatus?.baseline == "ok")
        #expect(payload.stageStatus?.largePacket == "ok")
        #expect(payload.baseline?.avgLatencyMs == 1.234)
        #expect(payload.baseline?.maxLatencyMs == 3.456)
        #expect(payload.baseline?.stddevMs == 0.512)
        #expect(payload.jitterTest?.stddevMs == 0.734)
        #expect(payload.jitterTest?.packetLossPercent == 0, "integer 0 decodes as Double")
        #expect(payload.jitterTest?.avgLatencyMs == nil, "jitter stage writes no average")
        #expect(payload.largePacketTest?.packetLossPercent == 0.0)
        #expect(payload.sustainedTest?.packetLossPercent == 0.5)
        #expect(payload.sustainedTest?.maxLatencyMs == 9.7)
        #expect(payload.recovery?.avgLatencyMs == 1.3)
        #expect(payload.recovery?.returnedToBaseline == true)
        #expect(payload.indicators?.packetLoss == true)
        #expect(payload.indicators?.highJitter == false)
        let ramping = try #require(payload.rampingTest)
        #expect(ramping.count == 5)
        #expect(ramping.map(\.packetSize) == [64, 256, 512, 1024, 1400])
        #expect(ramping.last?.packetLossPercent == 5.0)
        #expect(ramping.last?.avgLatencyMs == 2.1)
        #expect(payload.hasMeasurements)
        #expect(payload.stages.count == 6)
        #expect(payload.stages.map(\.kind) == [.baseline, .jitter, .largePacket, .ramping, .sustained, .recovery])
        #expect(payload.stages.filter { $0.metrics != nil }.count == 5)
        #expect(payload.stages[3].metrics == nil, "ramping metrics are per packet size")
        #expect(payload.stages.allSatisfy { $0.status == "ok" } == true)
        #expect(payload.methodology?.hasPrefix("ICMP-based") == true)
    }

    @Test("Task 14 uses the target_ip key and may be partial")
    func stressTestTargetIP() throws {
        let json = #"""
        {
          "status": "completed_with_warnings", "success": true, "error": null,
          "warnings": ["One or more stress sub-tests failed on this host or target. Results may be partial."],
          "function": "custom_target_stress_test", "target_ip": "10.1.1.9", "hostname": "nas.clienta.local", "interface": "en0",
          "completed_with_warnings": true,
          "warning": "One or more stress sub-tests failed on this host or target. Results may be partial.",
          "stage_status": {"baseline": "ok", "jitter": "failed", "large_packet": "ok", "ramping": "partial", "sustained": "ok", "recovery": "ok"},
          "baseline": {"avg_latency_ms": 0.9, "max_latency_ms": 1.4, "stddev_ms": 0.1},
          "jitter_test": {"stddev_ms": 0, "max_latency_ms": 0, "packet_loss_percent": 0},
          "large_packet_test": {"avg_latency_ms": 1.2, "max_latency_ms": 2.2, "packet_loss_percent": 0},
          "ramping_test": [
            {"packet_size": 64, "avg_latency_ms": 0.9, "max_latency_ms": 1.2, "packet_loss_percent": 0},
            {"packet_size": 256, "avg_latency_ms": 0, "max_latency_ms": 0, "packet_loss_percent": 100},
            {"packet_size": 512, "avg_latency_ms": 1.0, "max_latency_ms": 1.5, "packet_loss_percent": 0},
            {"packet_size": 1024, "avg_latency_ms": 1.1, "max_latency_ms": 1.9, "packet_loss_percent": 0},
            {"packet_size": 1400, "avg_latency_ms": 1.3, "max_latency_ms": 2.6, "packet_loss_percent": 0}
          ],
          "sustained_test": {"avg_latency_ms": 1.0, "max_latency_ms": 3.1, "packet_loss_percent": 0},
          "recovery": {"avg_latency_ms": 0.9, "returned_to_baseline": true},
          "indicators": {"high_jitter": false, "latency_under_load": false, "packet_loss": false, "slow_recovery": false},
          "methodology": "ICMP-based point-in-time stress test."
        }
        """#
        let (envelope, payload) = try decodeCore(StressTestPayload.self, task: .customStress, json)
        #expect(envelope.effectiveStatus == .completedWithWarnings)
        #expect(payload.function == "custom_target_stress_test")
        #expect(payload.gateway == nil)
        #expect(payload.targetIp == "10.1.1.9")
        #expect(payload.target == "10.1.1.9")
        #expect(payload.hostname == "nas.clienta.local")
        #expect(payload.completedWithWarnings == true)
        #expect(payload.warning?.hasPrefix("One or more stress sub-tests failed") == true)
        #expect(payload.stageStatus?.jitter == "failed")
        #expect(payload.stageStatus?.ramping == "partial")
        #expect(payload.stages[1].status == "failed")
        #expect(payload.stages[3].status == "partial")
        #expect(payload.jitterTest?.stddevMs == 0, "unparsed metrics are 0, never null")
        #expect(payload.rampingTest?[1].packetLossPercent == 100)
    }

    @Test("Stress failure-only file: envelope plus function, target key, hostname, interface")
    func stressTestFailureOnly() throws {
        let json = #"""
        {
          "status": "failed", "success": false,
          "error": {"code": "target_unreachable", "message": "Target 10.1.1.254 did not respond to any baseline ICMP echo request, so the stress stages were not run."},
          "warnings": [], "function": "gateway_stress_test", "gateway": "10.1.1.254", "hostname": "unknown", "interface": "en0"
        }
        """#
        let (envelope, payload) = try decodeCore(StressTestPayload.self, task: .gatewayStress, json)
        #expect(envelope.effectiveStatus == .failed)
        #expect(envelope.error?.code == "target_unreachable")
        #expect(payload.target == "10.1.1.254")
        #expect(payload.interface == "en0")
        #expect(payload.hasMeasurements == false)
        #expect(payload.stageStatus == nil)
        #expect(payload.baseline == nil)
        #expect(payload.rampingTest == nil)
        #expect(payload.indicators == nil)
        #expect(payload.stages.count == 6)
        #expect(payload.stages.allSatisfy { $0.status == nil && $0.metrics == nil } == true)
    }

    @Test("Task 10 early failure writes gateway and interface as null")
    func stressTestEarlyFailure() throws {
        let json = #"""
        {
          "status": "failed", "success": false,
          "error": {"code": "interface_info_missing", "message": "Gateway detection failed because Interface Network Info output was not available."},
          "warnings": [], "function": "gateway_stress_test", "gateway": null, "hostname": "unknown", "interface": null
        }
        """#
        let (envelope, payload) = try decodeCore(StressTestPayload.self, task: .gatewayStress, json)
        #expect(envelope.error?.code == "interface_info_missing")
        #expect(payload.gateway == nil)
        #expect(payload.target == nil)
        #expect(payload.interface == nil)
        #expect(payload.hasMeasurements == false)
    }

    @Test("Task 10 skipped for a public gateway")
    func stressTestSkipped() throws {
        let json = #"""
        {
          "status": "skipped", "success": false, "skip_reason": "gateway_public_ip",
          "skip_message": "Gateway IP 203.0.113.1 is publicly routable. Stress testing has been skipped.",
          "error": null, "warnings": [], "function": "gateway_stress_test", "gateway": "203.0.113.1",
          "hostname": "unknown", "interface": "en8"
        }
        """#
        let (envelope, payload) = try decodeCore(StressTestPayload.self, task: .gatewayStress, json)
        #expect(envelope.effectiveStatus == .skipped)
        #expect(envelope.effectiveStatus.isFailure == false)
        #expect(envelope.skipReason == "gateway_public_ip")
        #expect(payload.target == "203.0.113.1")
        #expect(payload.hasMeasurements == false)
    }

    @Test("Task 14 decodes through the core decoder with the same payload type as Task 10")
    func stressTestSharedType() throws {
        let gateway = try decodeCore(StressTestPayload.self, task: .gatewayStress, Self.stressSuccessJSON)
        let custom = try decodeCore(StressTestPayload.self, task: .customStress, Self.stressSuccessJSON)
        #expect(gateway.payload == custom.payload)
        #expect(StressTestPayload.taskIDs == [.gatewayStress, .customStress])
    }

    // MARK: - Task 11 — VLAN / Trunk

    @Test("Task 11 tagged frames with VLAN ids; status success despite a warning (hazard 6)")
    func vlanTrunkTagged() throws {
        let json = #"""
        {
          "status": "success", "success": true, "error": null,
          "warnings": ["No CDP or LLDP neighbour frames were received in the 65s capture window."],
          "interface": "en13", "tagged_frames_observed": true, "observed_vlan_ids": [10, 20, 50],
          "cdp_neighbours": [], "lldp_neighbours": [],
          "double_tag_probe": {"attempted": false, "vulnerable": null},
          "indicators": {"trunk_port_suspected": true, "cdp_exposed": false, "multiple_vlans_visible": true}
        }
        """#
        let (envelope, payload) = try decodeCore(VLANTrunkPayload.self, task: .vlanTrunk, json)
        #expect(envelope.effectiveStatus == .success)
        #expect(envelope.warnings.count == 1)
        #expect(payload.interface == "en13")
        #expect(payload.taggedFramesObserved == true)
        #expect(payload.observedVlanIds == [10, 20, 50])
        #expect(payload.cdpNeighbours?.isEmpty == true)
        #expect(payload.lldpNeighbours?.isEmpty == true)
        #expect(payload.doubleTagProbe?.attempted == false)
        #expect(payload.doubleTagProbe?.vulnerable == nil)
        #expect(payload.indicators?.trunkPortSuspected == true)
        #expect(payload.indicators?.cdpExposed == false)
        #expect(payload.indicators?.multipleVlansVisible == true)
    }

    @Test("Task 11 CDP and LLDP neighbours")
    func vlanTrunkNeighbours() throws {
        let json = #"""
        {
          "status": "success", "success": true, "error": null, "warnings": [],
          "interface": "en8", "tagged_frames_observed": false, "observed_vlan_ids": [],
          "cdp_neighbours": [
            {"device_id": "SW-CORE-01.clienta.local", "platform": "cisco WS-C2960X-48FPD-L", "port_id": "GigabitEthernet1/0/12",
             "native_vlan": 1, "vtp_domain": "CLIENTA", "duplex": "full"}
          ],
          "lldp_neighbours": [
            {"system_name": "USW-Pro-24", "chassis_id": "74:ac:b9:12:34:56", "port_id": "Port 7", "system_description": "USW-Pro-24, 7.0.50"}
          ],
          "double_tag_probe": {"attempted": false, "vulnerable": null},
          "indicators": {"trunk_port_suspected": false, "cdp_exposed": true, "multiple_vlans_visible": false}
        }
        """#
        let (_, payload) = try decodeCore(VLANTrunkPayload.self, task: .vlanTrunk, json)
        let cdp = try #require(payload.cdpNeighbours?.first)
        #expect(cdp.deviceId == "SW-CORE-01.clienta.local")
        #expect(cdp.platform == "cisco WS-C2960X-48FPD-L")
        #expect(cdp.portId == "GigabitEthernet1/0/12")
        #expect(cdp.nativeVlan == 1)
        #expect(cdp.vtpDomain == "CLIENTA")
        #expect(cdp.duplex == "full")
        let lldp = try #require(payload.lldpNeighbours?.first)
        #expect(lldp.systemName == "USW-Pro-24")
        #expect(lldp.chassisId == "74:ac:b9:12:34:56")
        #expect(lldp.portId == "Port 7")
        #expect(lldp.systemDescription == "USW-Pro-24, 7.0.50")
        #expect(payload.indicators?.cdpExposed == true)
    }

    @Test("Task 11 NO_INTERFACE failure contains only the envelope")
    func vlanTrunkEnvelopeOnly() throws {
        let json = #"""
        {"status": "failed", "success": false, "error": {"code": "NO_INTERFACE", "message": "No network interface selected."}, "warnings": []}
        """#
        let (envelope, payload) = try decodeCore(VLANTrunkPayload.self, task: .vlanTrunk, json)
        #expect(envelope.error?.code == "NO_INTERFACE")
        #expect(payload.interface == nil)
        #expect(payload.taggedFramesObserved == nil)
        #expect(payload.observedVlanIds == nil)
        #expect(payload.cdpNeighbours == nil)
        #expect(payload.doubleTagProbe == nil)
        #expect(payload.indicators == nil)
    }

    // MARK: - Task 12 — Duplicate IP

    @Test("Task 12 no duplicates")
    func duplicateIPNone() throws {
        let json = #"""
        {
          "status": "success", "success": true, "error": null, "warnings": [],
          "interface": "en0", "network": "10.1.1.0/24", "total_hosts_seen": 44, "duplicate_count": 0, "duplicates": []
        }
        """#
        let (_, payload) = try decodeCore(DuplicateIPPayload.self, task: .duplicateIP, json)
        #expect(payload.interface == "en0")
        #expect(payload.network == "10.1.1.0/24")
        #expect(payload.totalHostsSeen == 44)
        #expect(payload.duplicateCount == 0)
        #expect(payload.duplicates?.isEmpty == true)
        #expect(payload.hasDuplicates == false)
    }

    @Test("Task 12 duplicate found with parallel macs and vendors")
    func duplicateIPFound() throws {
        let json = #"""
        {
          "status": "completed_with_warnings", "success": true, "error": null,
          "warnings": ["1 IP address(es) responded to ARP from more than one MAC address, indicating an IP conflict or ARP spoofing."],
          "interface": "en0", "network": "10.1.1.0/24", "total_hosts_seen": 31, "duplicate_count": 1,
          "duplicates": [
            {"ip": "10.1.1.50", "macs": ["00:11:32:aa:bb:cc", "b8:27:eb:dd:ee:ff"], "vendors": ["Synology Incorporated", "Raspberry Pi Foundation"]}
          ]
        }
        """#
        let (envelope, payload) = try decodeCore(DuplicateIPPayload.self, task: .duplicateIP, json)
        #expect(envelope.effectiveStatus == .completedWithWarnings)
        #expect(payload.hasDuplicates)
        let duplicate = try #require(payload.duplicates?.first)
        #expect(duplicate.ip == "10.1.1.50")
        #expect(duplicate.macs == ["00:11:32:aa:bb:cc", "b8:27:eb:dd:ee:ff"])
        #expect(duplicate.vendors == ["Synology Incorporated", "Raspberry Pi Foundation"])
    }

    @Test("Task 12 failure: network null, zero counts")
    func duplicateIPFailure() throws {
        let json = #"""
        {
          "status": "failed", "success": false,
          "error": {"code": "NO_ARP_SCAN", "message": "arp-scan is not installed."},
          "warnings": [], "network": null, "interface": "en0", "total_hosts_seen": 0, "duplicate_count": 0, "duplicates": []
        }
        """#
        let (envelope, payload) = try decodeCore(DuplicateIPPayload.self, task: .duplicateIP, json)
        #expect(envelope.error?.code == "NO_ARP_SCAN")
        #expect(payload.network == nil)
        #expect(payload.totalHostsSeen == 0)
        #expect(payload.hasDuplicates == false)
    }

    // MARK: - Registry ownership

    @Test("decodeCoreAuditPayload owns tasks 1–12 and 14 and returns nil for the rest")
    func registryOwnership() throws {
        let minimal = Data(#"{"status": "success", "success": true, "error": null, "warnings": []}"#.utf8)
        let expectedTypes: [TaskID: String] = [
            .interfaceInfo: "InterfaceInfoPayload",
            .speedTest: "SpeedTestPayload",
            .gatewayDetails: "GatewayScanPayload",
            .dhcpScan: "DHCPScanPayload",
            .dhcpResponseTime: "DHCPResponseTimePayload",
            .dnsScan: "ServiceScanPayload",
            .ldapScan: "ServiceScanPayload",
            .smbNfsScan: "ServiceScanPayload",
            .printServerScan: "ServiceScanPayload",
            .gatewayStress: "StressTestPayload",
            .customStress: "StressTestPayload",
            .vlanTrunk: "VLANTrunkPayload",
            .duplicateIP: "DuplicateIPPayload",
        ]
        for task in TaskID.allCases {
            let result = try decodeCoreAuditPayload(task: task, data: minimal)
            if let expected = expectedTypes[task] {
                let decoded = try #require(result, "task \(task.rawValue) should be decoded here")
                #expect(String(describing: type(of: decoded.1)) == expected, "task \(task.rawValue)")
                #expect(decoded.0.effectiveStatus == .success)
            } else {
                #expect(result == nil, "task \(task.rawValue) belongs to the specialist decoder")
            }
        }
    }

    @Test("taskIDs of the core payload types cover exactly tasks 1–12 and 14")
    func taskIDCoverage() {
        let all: [[TaskID]] = [
            InterfaceInfoPayload.taskIDs, SpeedTestPayload.taskIDs, GatewayScanPayload.taskIDs,
            DHCPScanPayload.taskIDs, DHCPResponseTimePayload.taskIDs, ServiceScanPayload.taskIDs,
            StressTestPayload.taskIDs, VLANTrunkPayload.taskIDs, DuplicateIPPayload.taskIDs,
        ]
        let ids = all.flatMap { $0 }.map(\.rawValue)
        #expect(ids.count == Set(ids).count, "no task is claimed twice")
        #expect(ids.sorted() == Array(1...12) + [14])
    }

    @Test("Invalid JSON surfaces a decoding error instead of a payload")
    func invalidJSONThrows() {
        #expect(throws: (any Error).self) {
            try decodeCoreAuditPayload(task: .interfaceInfo, data: Data("{not json".utf8))
        }
    }

    @Test("A type mismatch on a boolean is reported with its key path")
    func typeMismatchDescribed() {
        let json = Data(#"{"status": "success", "success": true, "is_vm": "yes"}"#.utf8)
        do {
            _ = try decodeCoreAuditPayload(task: .interfaceInfo, data: json)
            Issue.record("expected a type mismatch")
        } catch {
            #expect(LSSJSON.describe(error).contains("isVm"))
        }
    }
}
