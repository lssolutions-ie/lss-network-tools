import LSSCore

extension TaskID {
    /// SF Symbol for the sidebar.
    var symbolName: String {
        switch self {
        case .interfaceInfo: "network"
        case .speedTest: "speedometer"
        case .gatewayDetails: "door.left.hand.open"
        case .dhcpScan: "server.rack"
        case .dhcpResponseTime: "timer"
        case .dnsScan: "globe"
        case .ldapScan: "person.3"
        case .smbNfsScan: "externaldrive.connected.to.line.below"
        case .printServerScan: "printer"
        case .gatewayStress: "waveform.path.ecg"
        case .vlanTrunk: "arrow.triangle.branch"
        case .duplicateIP: "doc.on.doc"
        case .customPortScan: "scope"
        case .customStress: "bolt.heart"
        case .customIdentity: "person.text.rectangle"
        case .customDNS: "magnifyingglass"
        case .wirelessSurvey: "wifi"
        case .unifiDiscovery: "antenna.radiowaves.left.and.right"
        case .unifiAdoption: "link.badge.plus"
        case .findByMAC: "location.magnifyingglass"
        }
    }

    /// One-sentence description shown in the task header.
    var summary: String {
        switch self {
        case .interfaceInfo: "Reads the selected interface's IPv4 address, mask, network range, gateway and MAC, and detects virtual-machine platforms."
        case .speedTest: "Measures internet download and upload speed and latency with speedtest-cli."
        case .gatewayDetails: "Scans every TCP port on the default gateway; skipped when the gateway is a public address."
        case .dhcpScan: "Sends DHCP discovery broadcasts five times, captures offers, and classifies every responder to spot rogue DHCP servers."
        case .dhcpResponseTime: "Times ten DHCP offers and estimates subnet utilisation."
        case .dnsScan: "Finds DNS servers on the subnet and checks resolution, recursion and rebinding behaviour."
        case .ldapScan: "Finds LDAP, Kerberos and Global Catalog services (Active Directory)."
        case .smbNfsScan: "Finds SMB and NFS file services and reports SMB signing requirements."
        case .printServerScan: "Finds printers and print servers (LPD, IPP, JetDirect)."
        case .gatewayStress: "Pings the gateway through baseline, jitter, large-packet, ramping, sustained and recovery stages. High impact — asks for confirmation."
        case .vlanTrunk: "Captures 802.1Q tags and CDP/LLDP neighbour frames to detect trunk ports and neighbouring switches."
        case .duplicateIP: "Uses arp-scan to find IP addresses answered by more than one MAC."
        case .customPortScan: "Full TCP port scan of a target IP you enter."
        case .customStress: "Stress-test profile against a target IP you enter. High impact — asks for confirmation."
        case .customIdentity: "Discovers MAC, vendor, services and a device-type hint for a target IP."
        case .customDNS: "Assesses a DNS server you enter: UDP/TCP queries, reverse lookup, recursion and version.bind."
        case .wirelessSurvey: "Room-by-room Wi-Fi survey recording SSIDs, signal, channels and access points."
        case .unifiDiscovery: "Finds Ubiquiti UniFi devices via ARP, UDP 10001 fingerprinting and LLDP."
        case .unifiAdoption: "Sends set-inform to the UniFi devices found by Task 18 so a controller can adopt them."
        case .findByMAC: "Finds the IP address currently using a MAC address on the subnet."
        }
    }
}
