import LSSCore
import SwiftUI

/// Task 3 — Gateway Details: the default gateway and its open TCP ports.
struct GatewayScanDetailView: View {
    let task: TaskID
    let payload: GatewayScanPayload

    private struct PortRow: Identifiable {
        let id: Int
        let port: Int

        var service: String? { WellKnownPorts.name(for: port) }
    }

    private var rows: [PortRow] {
        (payload.openPorts ?? []).enumerated().map { PortRow(id: $0.offset, port: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyValueGroup("Gateway", rows: [
                ("Gateway IP", Fmt.text(payload.gatewayIp)),
                ("Scan scope", Fmt.text(payload.scanScope)),
                ("Open TCP ports", Fmt.int(payload.openPorts?.count)),
            ])
            SectionCard("Open TCP ports", subtitle: rows.isEmpty ? nil : "Service names are the well-known assignment for the port, not a banner check") {
                if rows.isEmpty {
                    CoreAuditEmptyNote("No open TCP ports were recorded.")
                } else {
                    Table(rows) {
                        TableColumn("Port") { row in
                            Text(String(row.port)).monospacedDigit()
                        }
                        .width(min: 60, ideal: 90, max: 120)
                        TableColumn("Well-known service") { row in
                            Text(row.service ?? "—")
                        }
                    }
                    .coreAuditTableHeight(rows: rows.count)
                }
            }
        }
    }
}

/// IANA / de-facto assignments for ports commonly seen on gateways and the
/// labels `label_port_service` uses in the script.
private enum WellKnownPorts {
    static func name(for port: Int) -> String? {
        switch port {
        case 21: "ftp"
        case 22: "ssh"
        case 23: "telnet"
        case 25: "smtp"
        case 53: "dns"
        case 67, 68: "dhcp"
        case 80: "http"
        case 88: "kerberos"
        case 110: "pop3"
        case 111: "rpcbind"
        case 123: "ntp"
        case 135: "msrpc"
        case 139: "smb-netbios"
        case 143: "imap"
        case 161: "snmp"
        case 199: "smux"
        case 389: "ldap"
        case 443: "https"
        case 445: "smb"
        case 464: "kerberos-passwd"
        case 465, 587: "smtp-submission"
        case 515: "printer-lpd"
        case 548: "afp"
        case 593: "msrpc-http"
        case 631: "printer-ipp"
        case 636: "ldaps"
        case 993: "imaps"
        case 995: "pop3s"
        case 1194: "openvpn"
        case 1723: "pptp"
        case 2049: "nfs"
        case 3268: "ldap-global-catalog"
        case 3269: "ldaps-global-catalog"
        case 3306: "mysql"
        case 3389: "rdp"
        case 5060, 5061: "sip"
        case 5985, 5986: "winrm"
        case 8000, 8008, 8080, 8888: "http-alt"
        case 8443, 10443: "https-alt"
        case 9100: "printer-jetdirect"
        default: nil
        }
    }
}
