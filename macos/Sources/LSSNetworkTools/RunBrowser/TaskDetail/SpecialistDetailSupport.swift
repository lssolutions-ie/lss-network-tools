import SwiftUI
import LSSCore

// Helpers shared by the specialist detail views (Tasks 13, 15–20). Everything
// here carries a `specialist` prefix so it cannot collide with helpers of the
// core-audit views that live in the same directory.

extension View {
    /// A `Table` inside the detail scroll view has no intrinsic height, so give
    /// it one from its row count (header + rows). Long lists are capped and
    /// scroll inside the table.
    func specialistTableHeight(rows: Int, maxVisibleRows: Int = 12) -> some View {
        let visible = max(1, min(rows, maxVisibleRows))
        return frame(height: CGFloat(visible) * 26 + 34)
    }
}

/// Short grey note shown instead of an empty table.
struct SpecialistEmptyNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Formatting not covered by `Fmt`.
enum SpecialistFmt {
    /// `-61 dBm`; `nil` for a missing value.
    static func dbm(_ value: Double?) -> String? {
        guard let value else { return nil }
        return value == value.rounded() ? "\(Int(value)) dBm" : String(format: "%.1f dBm", value)
    }
}

/// Sort keys for table columns whose natural order is not the string order.
enum SpecialistSort {
    /// Numeric key for a dotted-quad IPv4 string so `.9` sorts before `.10`;
    /// unparsable or missing addresses sort last.
    static func ipv4Key(_ ip: String?) -> UInt32 {
        guard let ip else { return .max }
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return .max }
        return parts.reduce(0) { ($0 << 8) | $1 }
    }
}

/// Names for the ports a port scan most often turns up (nmap's service names).
enum SpecialistPortNames {
    private static let names: [Int: String] = [
        21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 53: "domain", 67: "dhcps", 80: "http",
        88: "kerberos", 110: "pop3", 111: "rpcbind", 123: "ntp", 135: "msrpc", 137: "netbios-ns",
        139: "netbios-ssn", 143: "imap", 161: "snmp", 389: "ldap", 443: "https", 445: "microsoft-ds",
        465: "smtps", 515: "printer", 548: "afp", 587: "submission", 631: "ipp", 636: "ldaps",
        993: "imaps", 995: "pop3s", 1433: "ms-sql-s", 1900: "upnp", 2049: "nfs", 3268: "globalcatLDAP",
        3269: "globalcatLDAPssl", 3306: "mysql", 3389: "ms-wbt-server", 5000: "upnp",
        5001: "commplex-link", 5353: "mdns", 5432: "postgresql", 5900: "vnc", 8080: "http-proxy",
        8443: "https-alt", 9100: "jetdirect", 10001: "ubnt-discovery",
    ]

    static func name(for port: Int) -> String? { names[port] }
}

extension Color {
    /// sRGB colour from a `0xRRGGBB` literal (the chart palette values).
    static func specialistHex(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}
