import Foundation

/// The three sidebar groups the 20 tasks fall into.
public enum TaskGroup: String, CaseIterable, Sendable, Identifiable {
    case coreAudit
    case customTarget
    case specialist

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .coreAudit: "Core Audit (1–12)"
        case .customTarget: "Custom Target (13–16)"
        case .specialist: "Specialist (17–20)"
        }
    }

    public var tasks: [TaskID] { TaskID.allCases.filter { $0.group == self } }
}

/// The 20 tasks of `lss-network-tools.sh`. The raw value is the task number used
/// everywhere in the bash script (TASKS_DATA, run_task_by_id, menus).
///
/// `title` and `outputFile` mirror TASKS_DATA exactly; `TaskIDTests` parses the
/// script and fails if they drift.
public enum TaskID: Int, CaseIterable, Sendable, Identifiable, Codable, Comparable, Hashable {
    case interfaceInfo = 1
    case speedTest
    case gatewayDetails
    case dhcpScan
    case dhcpResponseTime
    case dnsScan
    case ldapScan
    case smbNfsScan
    case printServerScan
    case gatewayStress
    case vlanTrunk
    case duplicateIP
    case customPortScan
    case customStress
    case customIdentity
    case customDNS
    case wirelessSurvey
    case unifiDiscovery
    case unifiAdoption
    case findByMAC

    public var id: Int { rawValue }

    public static func < (lhs: TaskID, rhs: TaskID) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Title as listed in TASKS_DATA.
    public var title: String {
        switch self {
        case .interfaceInfo: "Interface Network Info"
        case .speedTest: "Internet Speed Test"
        case .gatewayDetails: "Gateway Details"
        case .dhcpScan: "DHCP Network Scan"
        case .dhcpResponseTime: "DHCP Response Time"
        case .dnsScan: "DNS Network Scan"
        case .ldapScan: "LDAP/AD Network Scan"
        case .smbNfsScan: "SMB/NFS Network Scan"
        case .printServerScan: "Printer/Print Server Network Scan"
        case .gatewayStress: "Gateway Stress Test"
        case .vlanTrunk: "VLAN/Trunk Detection"
        case .duplicateIP: "Duplicate IP Detection"
        case .customPortScan: "Custom Target Port Scan"
        case .customStress: "Custom Target Stress Test"
        case .customIdentity: "Custom Target Identity Scan"
        case .customDNS: "Custom Target DNS Assessment"
        case .wirelessSurvey: "Wireless Site Survey"
        case .unifiDiscovery: "Scan For UniFi Devices"
        case .unifiAdoption: "UniFi Adoption"
        case .findByMAC: "Find Device by MAC"
        }
    }

    /// Output file name as listed in TASKS_DATA. Multi-entry tasks write
    /// `<stem>-device-N.json` instead (see `isMultiEntry`).
    public var outputFile: String {
        switch self {
        case .interfaceInfo: "interface-network-info.json"
        case .speedTest: "internet-speed-test.json"
        case .gatewayDetails: "gateway-scan.json"
        case .dhcpScan: "dhcp-scan.json"
        case .dhcpResponseTime: "dhcp-response-time.json"
        case .dnsScan: "dns-scan.json"
        case .ldapScan: "ldap-ad-scan.json"
        case .smbNfsScan: "smb-nfs-scan.json"
        case .printServerScan: "print-server-scan.json"
        case .gatewayStress: "gateway-stress-test.json"
        case .vlanTrunk: "vlan-trunk-scan.json"
        case .duplicateIP: "duplicate-ip-scan.json"
        case .customPortScan: "custom-target-port-scan.json"
        case .customStress: "custom-target-stress-test.json"
        case .customIdentity: "custom-target-identity-scan.json"
        case .customDNS: "custom-target-dns-assessment.json"
        case .wirelessSurvey: "wireless-survey.json"
        case .unifiDiscovery: "unifi-discovery.json"
        case .unifiAdoption: "unifi-adoption.json"
        case .findByMAC: "find-device-by-mac.json"
        }
    }

    /// `outputFile` without the `.json` extension.
    public var outputStem: String {
        outputFile.hasSuffix(".json") ? String(outputFile.dropLast(5)) : outputFile
    }

    public var group: TaskGroup {
        switch rawValue {
        case 1...12: .coreAudit
        case 13...16: .customTarget
        default: .specialist
        }
    }

    /// Tasks whose results are written as `<stem>-device-N.json` (one file per run of the task).
    public var isMultiEntry: Bool { [10, 13, 14, 15, 16].contains(rawValue) }

    /// Tasks that flood the target with ICMP and require explicit consent.
    public var isStressTest: Bool { self == .gatewayStress || self == .customStress }

    /// Tasks run by the `000` complete audit.
    public var isAuditTask: Bool { rawValue <= 12 }

    /// Tasks that prompt for a target IPv4 address.
    public var needsTargetIP: Bool { (13...16).contains(rawValue) }

    /// Task that prompts for a MAC address.
    public var needsMAC: Bool { self == .findByMAC }

    /// Task IDs run by the complete audit, in order (mirrors `get_audit_task_ids`).
    public static var auditTasks: [TaskID] { allCases.filter(\.isAuditTask) }
}
