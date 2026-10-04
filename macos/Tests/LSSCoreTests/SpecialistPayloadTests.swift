import Foundation
import Testing
@testable import LSSCore

/// `macos/Tests/Fixtures/synthetic/`, relative to this file (macos/Tests/LSSCoreTests/).
private var syntheticFixturesURL: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent() // LSSCoreTests
        .deletingLastPathComponent() // Tests
        .appending(path: "Fixtures/synthetic")
}

private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: syntheticFixturesURL.appending(path: name))
}

/// Decodes a synthetic fixture through `decodeSpecialistPayload` and casts the payload.
private func decodeFixture<P: TaskPayload>(_ name: String, task: TaskID, as type: P.Type) throws -> (envelope: TaskEnvelope, payload: P) {
    let decoded = try #require(try decodeSpecialistPayload(task: task, data: fixtureData(name)), "\(name) returned nil")
    let payload = try #require(decoded.1 as? P, "\(name) decoded as \(Swift.type(of: decoded.1)), expected \(P.self)")
    return (decoded.0, payload)
}

@Suite("Specialist payloads (Tasks 13, 15–20)")
struct SpecialistPayloadTests {
    private static func expectedTypeName(for task: TaskID) -> String? {
        switch task {
        case .customPortScan: "CustomPortScanPayload"
        case .customIdentity: "IdentityScanPayload"
        case .customDNS: "DNSAssessmentPayload"
        case .wirelessSurvey: "WirelessSurveyPayload"
        case .unifiDiscovery: "UniFiDiscoveryPayload"
        case .unifiAdoption: "UniFiAdoptionPayload"
        case .findByMAC: "FindByMACPayload"
        default: nil
        }
    }

    @Test("Every synthetic fixture decodes (stress-test shapes are left to decodeCoreAuditPayload)")
    func allSyntheticFixturesDecode() throws {
        let files = try FileManager.default.contentsOfDirectory(at: syntheticFixturesURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count >= 29)

        for file in files {
            let name = file.lastPathComponent
            let number = try #require(Int(name.split(separator: "-")[1]), "fixture name must be task-NN-<case>.json: \(name)")
            let task = try #require(TaskID(rawValue: number), "unknown task \(number) in \(name)")
            let data = try Data(contentsOf: file)

            // The raw-JSON view must never fail, whatever the typed decode does.
            #expect(try LSSJSON.decode(JSONValue.self, from: data).isObject, "\(name) is not a JSON object")

            let decoded = try decodeSpecialistPayload(task: task, data: data)
            if task.isStressTest {
                #expect(decoded == nil, "\(name): Tasks 10/14 belong to decodeCoreAuditPayload")
                let (envelope, payload) = try #require(try decodeCoreAuditPayload(task: task, data: data), "\(name) did not decode through decodeCoreAuditPayload")
                #expect(envelope.status != nil, "\(name) has no status")
                #expect(payload is StressTestPayload, "\(name) decoded as the wrong payload type")
            } else {
                let (envelope, payload) = try #require(decoded, "\(name) did not decode")
                #expect(envelope.status != nil, "\(name) has no status")
                #expect(String(describing: type(of: payload)) == Self.expectedTypeName(for: task), "\(name) decoded as the wrong payload type")
            }
        }
    }

    @Test("decodeSpecialistPayload returns nil for Tasks 1–12 and 14")
    func returnsNilForForeignTasks() throws {
        let data = try fixtureData("task-13-success.json")
        for task in TaskID.allCases where task.rawValue <= 12 || task == .customStress {
            #expect(try decodeSpecialistPayload(task: task, data: data) == nil, "task \(task.rawValue) should not be decoded here")
        }
    }

    @Test("taskIDs cover exactly Tasks 13 and 15–20")
    func taskIDs() {
        let owned = CustomPortScanPayload.taskIDs + IdentityScanPayload.taskIDs + DNSAssessmentPayload.taskIDs
            + WirelessSurveyPayload.taskIDs + UniFiDiscoveryPayload.taskIDs + UniFiAdoptionPayload.taskIDs
            + FindByMACPayload.taskIDs
        #expect(owned.map(\.rawValue).sorted() == [13, 15, 16, 17, 18, 19, 20])
    }

    // MARK: Task 13

    @Test("Task 13 success lists the open ports")
    func portScanSuccess() throws {
        let (envelope, payload) = try decodeFixture("task-13-success.json", task: .customPortScan, as: CustomPortScanPayload.self)
        #expect(envelope.status == .success)
        #expect(payload.targetIp == "192.168.1.20")
        #expect(payload.hostname == "nas-01.lan")
        #expect(payload.scanType == "custom_target_port_scan")
        #expect(payload.openPorts == [22, 80, 139, 443, 445, 2049, 5000, 5001])
    }

    @Test("Task 13 keeps every key with an empty port list on failure and when nothing is open")
    func portScanEmptyShapes() throws {
        let failed = try decodeFixture("task-13-failed.json", task: .customPortScan, as: CustomPortScanPayload.self)
        #expect(failed.envelope.status == .failed)
        #expect(failed.envelope.error?.code == "custom_target_port_scan_failed")
        #expect(failed.payload.openPorts == [])
        #expect(failed.payload.hostname == "unknown")

        let empty = try decodeFixture("task-13-no-open-ports.json", task: .customPortScan, as: CustomPortScanPayload.self)
        #expect(empty.envelope.status == .completedWithWarnings)
        #expect(empty.envelope.warnings.count == 2)
        #expect(empty.payload.openPorts?.isEmpty == true)
    }

    // MARK: Task 15

    @Test("Task 15 success decodes the identity fields and the service table")
    func identitySuccess() throws {
        let (envelope, payload) = try decodeFixture("task-15-success.json", task: .customIdentity, as: IdentityScanPayload.self)
        #expect(envelope.status == .success)
        #expect(payload.macAddress == "3C:D9:2B:4A:1F:88")
        #expect(payload.vendor == "Hewlett Packard")
        #expect(payload.vendorSource == "nmap")
        #expect(payload.lookupMethod == "nmap")
        #expect(payload.hostState == "up")
        #expect(payload.deviceTypeHint == "printer")
        #expect(payload.deviceTypeLabel == "printer")
        #expect(payload.confidence == "medium")
        #expect(payload.identitySummary == "Likely network printer")

        let services = try #require(payload.services)
        #expect(services.count == 5)
        #expect(services[0].port == "80/tcp")
        #expect(services[0].portNumber == 80)
        #expect(services[0].transport == "tcp")
        #expect(services[2].version == "")
        #expect(services[4].portNumber == 9100)
        #expect(services[4].service == "jetdirect")
    }

    @Test("Task 15 arp-cache lookup with a gateway warning")
    func identityGatewayWarning() throws {
        let (envelope, payload) = try decodeFixture("task-15-gateway-warning.json", task: .customIdentity, as: IdentityScanPayload.self)
        #expect(envelope.status == .completedWithWarnings)
        #expect(envelope.warnings == ["The target IP matches the current default gateway for interface en0."])
        #expect(payload.lookupMethod == "arp-cache")
        #expect(payload.vendorSource == "macvendors-api")
        #expect(payload.deviceTypeHint == "firewall-or-router")
        #expect(payload.deviceTypeLabel == "firewall or router")
        #expect(payload.confidence == "high")
    }

    @Test("Task 15 host down: null MAC, unknown vendor, empty services")
    func identityHostDown() throws {
        let (envelope, payload) = try decodeFixture("task-15-host-down.json", task: .customIdentity, as: IdentityScanPayload.self)
        #expect(envelope.warnings.count == 3)
        #expect(payload.macAddress == nil)
        #expect(payload.vendor == "unknown")
        #expect(payload.hostState == "down")
        #expect(payload.deviceTypeLabel == nil)
        #expect(payload.services?.isEmpty == true)
    }

    @Test("Task 15 failure file carries only target_ip and hostname")
    func identityFailure() throws {
        let (envelope, payload) = try decodeFixture("task-15-discovery-failed.json", task: .customIdentity, as: IdentityScanPayload.self)
        #expect(envelope.status == .failed)
        #expect(envelope.success == false)
        #expect(envelope.error?.code == "custom_identity_discovery_failed")
        #expect(payload.targetIp == "192.168.1.88")
        #expect(payload.hostname == "unknown")
        #expect(payload.macAddress == nil)
        #expect(payload.hostState == nil)
        #expect(payload.services == nil)
    }

    // MARK: Task 16

    @Test("Task 16 success with dig")
    func dnsSuccess() throws {
        let (envelope, payload) = try decodeFixture("task-16-success.json", task: .customDNS, as: DNSAssessmentPayload.self)
        #expect(envelope.status == .success)
        #expect(payload.queryTool == "dig")
        #expect(payload.dnsServiceWorking == true)
        #expect(payload.recursionAvailable == true)
        #expect(payload.udpQuery?.status == "NOERROR")
        #expect(payload.udpQuery?.answers == ["203.0.113.34"])
        #expect(payload.tcpQuery?.status == "NOERROR")
        #expect(payload.reversePtrQuery?.answers == ["dns.google."])
        #expect(payload.versionBindResponse == "unbound 1.21.0")
        #expect(payload.softwareHint == "unbound 1.21.0")
        #expect(payload.upstreamDestinationInference == "unknown")
        #expect(payload.upstreamVisibilityNote?.isEmpty == false)
    }

    @Test("Task 16 refusing resolver and nslookup fallback")
    func dnsDegradedShapes() throws {
        let refused = try decodeFixture("task-16-not-recursive.json", task: .customDNS, as: DNSAssessmentPayload.self)
        #expect(refused.envelope.status == .completedWithWarnings)
        #expect(refused.payload.dnsServiceWorking == false)
        #expect(refused.payload.recursionAvailable == false)
        #expect(refused.payload.udpQuery?.status == "REFUSED")
        #expect(refused.payload.udpQuery?.answers == [])
        #expect(refused.payload.versionBindResponse == nil)
        #expect(refused.payload.softwareHint == "unknown")

        let nslookup = try decodeFixture("task-16-nslookup.json", task: .customDNS, as: DNSAssessmentPayload.self)
        #expect(nslookup.payload.queryTool == "nslookup")
        #expect(nslookup.payload.tcpQuery?.status == "unknown")
        #expect(nslookup.payload.udpQuery?.answers == [])
        #expect(nslookup.envelope.warnings == ["TCP and version.bind assessment is limited when dig is not available."])
    }

    @Test("Task 16 dns_query_tool_missing carries only the target")
    func dnsToolMissing() throws {
        let (envelope, payload) = try decodeFixture("task-16-tool-missing.json", task: .customDNS, as: DNSAssessmentPayload.self)
        #expect(envelope.status == .failed)
        #expect(envelope.error?.code == "dns_query_tool_missing")
        #expect(payload.targetIp == "192.168.1.53")
        #expect(payload.queryTool == nil)
        #expect(payload.udpQuery == nil)
        #expect(payload.dnsServiceWorking == nil)
    }

    // MARK: Task 17

    @Test("Task 17 CoreWLAN shape: nine keys, null RSSI, hidden SSID")
    func wirelessCoreWLAN() throws {
        let (envelope, payload) = try decodeFixture("task-17-corewlan.json", task: .wirelessSurvey, as: WirelessSurveyPayload.self)
        #expect(envelope.status == .success)
        #expect(payload.interface == "en0")
        #expect(payload.roomsScanned == 3)
        let rooms = try #require(payload.survey)
        #expect(rooms.count == payload.roomsScanned)
        #expect(payload.allNetworks.count == 15)

        let reception = rooms[0]
        #expect(reception.displayName == "Main Building · Ground · Reception")
        #expect(reception.apPresent == true)
        #expect(reception.apLabel == "AP-G01")
        #expect(reception.timestampDate != nil)
        let networks = try #require(reception.networks)
        #expect(networks.count == 6)

        let strongest = networks[0]
        #expect(strongest.ssid == "Staff-WiFi")
        #expect(strongest.displaySSID == "Staff-WiFi")
        #expect(strongest.rssiDbm == -41)
        #expect(strongest.signalDbm == -41)
        #expect(strongest.noiseFloorDbm == -92)
        #expect(strongest.channel == "36")
        #expect(strongest.channelNumber == 36)
        #expect(strongest.band == "5GHz")
        #expect(strongest.bandLabel == "5GHz")
        #expect(strongest.channelWidth == "80MHz")
        #expect(strongest.phyMode == "--")
        #expect(strongest.security == "--")

        let hidden = networks[3]
        #expect(hidden.ssid == "(hidden)")
        #expect(hidden.isHidden)
        #expect(hidden.displaySSID == "Hidden network")

        let noSignal = networks[5]
        #expect(noSignal.rssiDbm == nil)
        #expect(noSignal.signalDbm == nil)
        #expect(noSignal.noiseFloorDbm == nil)

        let room101 = rooms[1]
        #expect(room101.apPresent == false)
        #expect(room101.apLabel == nil)
    }

    @Test("Task 17 legacy airport shape: five keys, band inferred from the channel")
    func wirelessAirportLegacy() throws {
        let (_, payload) = try decodeFixture("task-17-airport-legacy.json", task: .wirelessSurvey, as: WirelessSurveyPayload.self)
        let networks = try #require(payload.survey?.first?.networks)
        #expect(networks.count == 5)
        #expect(networks[0].channel == "36,+1")
        #expect(networks[0].channelNumber == 36)
        #expect(networks[0].band == nil)
        #expect(networks[0].bandLabel == "5GHz")
        #expect(networks[0].noiseFloorDbm == nil)
        #expect(networks[0].channelWidth == nil)
        #expect(networks[0].phyMode == nil)
        #expect(networks[2].bandLabel == "2.4GHz")
        #expect(networks[4].security == "NONE")
        #expect(networks[4].channelNumber == 149)
    }

    @Test("Task 17 system_profiler ended-early and Linux iw shapes")
    func wirelessOtherScanners() throws {
        let early = try decodeFixture("task-17-ended-early.json", task: .wirelessSurvey, as: WirelessSurveyPayload.self)
        #expect(early.envelope.status == .completedWithWarnings)
        #expect(early.envelope.warnings.count == 1)
        #expect(early.payload.roomsScanned == 1)
        let profilerNetwork = try #require(early.payload.survey?.first?.networks?.first)
        #expect(profilerNetwork.bssid == "--")
        #expect(profilerNetwork.phyMode == "802.11ax (Wi-Fi 6)")
        #expect(profilerNetwork.security == "WPA2")

        let linux = try decodeFixture("task-17-linux-iw.json", task: .wirelessSurvey, as: WirelessSurveyPayload.self)
        #expect(linux.payload.interface == "wlan0")
        let iwNetworks = try #require(linux.payload.survey?.first?.networks)
        #expect(iwNetworks[1].channelWidth == "1 (80 MHz)")
        #expect(iwNetworks[1].bandLabel == "5GHz")
        let blank = iwNetworks[2]
        #expect(blank.ssid == "")
        #expect(blank.isHidden)
        #expect(blank.displaySSID == "Hidden network")
        #expect(blank.rssiDbm == 0)
        #expect(blank.signalDbm == nil)
        #expect(blank.channelNumber == nil)
        #expect(blank.bandLabel == nil)
    }

    @Test("Task 17 NO_WIRELESS_INTERFACE failure")
    func wirelessFailure() throws {
        let (envelope, payload) = try decodeFixture("task-17-no-wireless-interface.json", task: .wirelessSurvey, as: WirelessSurveyPayload.self)
        #expect(envelope.status == .failed)
        #expect(envelope.error?.code == "NO_WIRELESS_INTERFACE")
        #expect(payload.interface == nil)
        #expect(payload.roomsScanned == 0)
        #expect(payload.survey?.isEmpty == true)
        #expect(payload.allNetworks.isEmpty)
    }

    @Test("Task 17 lenient fields accept string counts, string RSSI and numeric channels")
    func wirelessLenientTypes() throws {
        let json = """
        {"status":"success","success":true,"error":null,"warnings":[],"scan_type":"wireless_site_survey",
         "interface":"en0","rooms_scanned":"1","survey":[{"building":"B","floor":"1","room":"R","ap_present":false,
         "ap_label":null,"timestamp":"2026-06-11T09:42:17Z","networks":[
           {"ssid":"X","bssid":"aa:bb:cc:dd:ee:ff","rssi_dbm":"-61","channel":36,"security":"WPA2"}]}]}
        """
        let decoded = try #require(try decodeSpecialistPayload(task: .wirelessSurvey, data: Data(json.utf8)))
        let payload = try #require(decoded.1 as? WirelessSurveyPayload)
        #expect(payload.roomsScanned == 1)
        let network = try #require(payload.survey?.first?.networks?.first)
        #expect(network.rssiDbm == -61)
        #expect(network.channel == "36")
        #expect(network.channelNumber == 36)
    }

    // MARK: Task 18

    @Test("Task 18 success flags the probable device and keeps false positives apart")
    func unifiDiscoverySuccess() throws {
        let (envelope, payload) = try decodeFixture("task-18-success.json", task: .unifiDiscovery, as: UniFiDiscoveryPayload.self)
        #expect(envelope.status == .success)
        #expect(payload.interface == "en0")
        #expect(payload.broadcast == "192.168.1.255")
        #expect(payload.subnet == "192.168.1.0/24")
        #expect(payload.devicesFound == 5)

        let devices = try #require(payload.devices)
        #expect(devices.count == payload.devicesFound)
        #expect(devices[0].mac == "74:ac:b9:12:3e:40")
        #expect(devices[0].model == "U6-LR")
        #expect(devices[0].isProbable == false)
        #expect(devices[3].model == nil)
        #expect(devices[4].confidence == "probable")
        #expect(devices[4].isProbable)
        #expect(payload.confirmedDevices.count == 4)
        #expect(payload.probableDevices.map(\.ip) == ["192.168.1.60"])

        let falsePositives = try #require(payload.falsePositives)
        #expect(falsePositives.count == 2)
        #expect(falsePositives[1].mac == "unknown")
        #expect(falsePositives[1].model == nil)
    }

    @Test("Task 18 failure shapes")
    func unifiDiscoveryFailures() throws {
        let privileges = try decodeFixture("task-18-insufficient-privileges.json", task: .unifiDiscovery, as: UniFiDiscoveryPayload.self)
        #expect(privileges.envelope.status == .failed)
        #expect(privileges.envelope.error?.code == "insufficient_privileges")
        #expect(privileges.payload.devicesFound == 0)
        #expect(privileges.payload.devices?.isEmpty == true)
        #expect(privileges.payload.falsePositives?.isEmpty == true)
        #expect(privileges.payload.broadcast == nil)

        let noSubnet = try decodeFixture("task-18-no-subnet.json", task: .unifiDiscovery, as: UniFiDiscoveryPayload.self)
        #expect(noSubnet.envelope.error?.code == "no_subnet")
        #expect(noSubnet.payload.subnet == "")
        #expect(noSubnet.payload.falsePositives == nil)

        let none = try decodeFixture("task-18-none-found.json", task: .unifiDiscovery, as: UniFiDiscoveryPayload.self)
        #expect(none.envelope.status == .success)
        #expect(none.payload.confirmedDevices.isEmpty)
        #expect(none.payload.falsePositives == [])
    }

    // MARK: Task 19

    @Test("Task 19 success with mixed results and no warnings key")
    func unifiAdoptionSuccess() throws {
        let (envelope, payload) = try decodeFixture("task-19-success.json", task: .unifiAdoption, as: UniFiAdoptionPayload.self)
        #expect(envelope.status == .success)
        #expect(envelope.error == nil)
        #expect(envelope.warnings.isEmpty)
        #expect(payload.controller == "10.0.0.5")
        #expect(payload.informUrl == "http://10.0.0.5:8080/inform")
        #expect(payload.devicesFound == 4)
        #expect(payload.devicesAdopted == 2)

        let devices = try #require(payload.devices)
        #expect(devices.count == 4)
        #expect(devices[0].isAdopted)
        #expect(devices[0].failureReason == nil)
        #expect(devices[2].isAdopted == false)
        #expect(devices[2].failureReason == "authentication failed (wrong password?)")
        #expect(devices[3].failureReason == "could not connect")
        #expect(payload.failedDevices.count == 2)
    }

    @Test("Task 19 reports success even when every adoption failed")
    func unifiAdoptionAllFailed() throws {
        let (envelope, payload) = try decodeFixture("task-19-all-failed.json", task: .unifiAdoption, as: UniFiAdoptionPayload.self)
        #expect(envelope.status == .success)
        #expect(payload.devicesFound == 1)
        #expect(payload.devicesAdopted == 0)
        #expect(payload.failedDevices.count == 1)
        #expect(payload.informUrl == "https://10.0.0.5:443/inform")
    }

    @Test("Task 19 missing_dependency failure has an error but no warnings key")
    func unifiAdoptionMissingDependency() throws {
        let (envelope, payload) = try decodeFixture("task-19-missing-dependency.json", task: .unifiAdoption, as: UniFiAdoptionPayload.self)
        #expect(envelope.status == .failed)
        #expect(envelope.error?.code == "missing_dependency")
        #expect(envelope.warnings.isEmpty)
        #expect(payload.controller == nil)
        #expect(payload.informUrl == nil)
        #expect(payload.devicesFound == 0)
        #expect(payload.devices?.isEmpty == true)
    }

    // MARK: Task 20

    @Test("Task 20 found / not found / failures")
    func findByMAC() throws {
        let found = try decodeFixture("task-20-found.json", task: .findByMAC, as: FindByMACPayload.self)
        #expect(found.envelope.status == .success)
        #expect(found.envelope.warnings.isEmpty)
        #expect(found.payload.macQueried == "3c:d9:2b:4a:1f:88")
        #expect(found.payload.ipFound == "192.168.1.31")
        #expect(found.payload.isFound)
        #expect(found.payload.subnet == "192.168.1.0/24")

        let notFound = try decodeFixture("task-20-not-found.json", task: .findByMAC, as: FindByMACPayload.self)
        #expect(notFound.envelope.status == .success)
        #expect(notFound.payload.ipFound == nil)
        #expect(notFound.payload.isFound == false)

        let privileges = try decodeFixture("task-20-insufficient-privileges.json", task: .findByMAC, as: FindByMACPayload.self)
        #expect(privileges.envelope.status == .failed)
        #expect(privileges.envelope.error?.code == "insufficient_privileges")
        #expect(privileges.payload.isFound == false)

        let noSubnet = try decodeFixture("task-20-no-subnet.json", task: .findByMAC, as: FindByMACPayload.self)
        #expect(noSubnet.envelope.error?.code == "no_subnet")
        #expect(noSubnet.payload.subnet == "")
        #expect(noSubnet.payload.interface == "en5")
    }

    // MARK: Tasks 10 / 14 (shared StressTestPayload, owned by CoreAuditPayloads.swift)

    @Test("Task 10 skipped and Task 14 failure decode through the shared StressTestPayload; the specialist decoder declines them")
    func stressTestShapes() throws {
        let skipped = try fixtureData("task-10-skipped.json")
        #expect(try decodeSpecialistPayload(task: .gatewayStress, data: skipped) == nil)
        let (skippedEnvelope, skippedPayload) = try #require(try decodeCoreAuditPayload(task: .gatewayStress, data: skipped))
        #expect(skippedEnvelope.status == .skipped)
        #expect(skippedEnvelope.success == false)
        #expect(skippedEnvelope.effectiveStatus.isFailure == false)
        #expect(skippedEnvelope.skipReason == "gateway_public_ip")
        #expect(skippedEnvelope.skipMessage?.hasPrefix("Gateway IP 203.0.113.1 is publicly routable") == true)
        #expect(skippedEnvelope.error == nil)
        let skippedStress = try #require(skippedPayload as? StressTestPayload)
        #expect(skippedStress.target == "203.0.113.1")

        let unreachable = try fixtureData("task-14-target-unreachable.json")
        #expect(try decodeSpecialistPayload(task: .customStress, data: unreachable) == nil)
        let (unreachableEnvelope, unreachablePayload) = try #require(try decodeCoreAuditPayload(task: .customStress, data: unreachable))
        #expect(unreachableEnvelope.status == .failed)
        #expect(unreachableEnvelope.error?.code == "target_unreachable")
        let unreachableStress = try #require(unreachablePayload as? StressTestPayload)
        #expect(unreachableStress.target == "192.168.1.250")
        let tree = try LSSJSON.decode(JSONValue.self, from: unreachable)
        #expect(tree["function"]?.stringValue == "custom_target_stress_test")
    }
}
