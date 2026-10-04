import AppKit
import SwiftUI

// Helpers shared by the core-audit detail views (tasks 1–12 and 14). Every
// name carries a `CoreAudit` prefix so it cannot collide with the specialist
// views' helpers or the run browser's own components in the same module.

/// Chart colours. The two series colours are categorical slots 1 and 2 of the
/// reference data-viz palette — an adjacent pair that clears the colour-vision
/// deficiency gate in both appearances — stepped separately for light and dark.
/// `critical` is a status colour: it marks lost probes / packet loss and is
/// never used for an ordinary series; `neutral` de-emphasises a zero value.
enum CoreAuditChartPalette {
    static let series1 = Color.coreAuditDynamic(light: 0x2A78D6, dark: 0x3987E5)
    static let series2 = Color.coreAuditDynamic(light: 0xEB6834, dark: 0xD95926)
    static let critical = Color.coreAuditDynamic(light: 0xD03B3B, dark: 0xD03B3B)
    static let neutral = Color.coreAuditDynamic(light: 0x898781, dark: 0x898781)
}

extension Color {
    /// A colour that follows the system appearance (`0xRRGGBB` light / dark values).
    static func coreAuditDynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(coreAuditHex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(coreAuditHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension View {
    /// Gives a `Table` an explicit height so it lays out inside the scrolling
    /// detail pane instead of collapsing; past `maxRows` the table scrolls itself.
    func coreAuditTableHeight(rows: Int, maxRows: Int = 12) -> some View {
        frame(height: CGFloat(max(1, min(rows, maxRows))) * 26 + 36)
    }
}

/// Short secondary text shown instead of an empty table or chart.
struct CoreAuditEmptyNote: View {
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

/// Footnote under a task's cards (the script's `methodology` / `discovery_note`).
struct CoreAuditNote: View {
    let text: String?

    var body: some View {
        if let text = Fmt.text(text) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Sort keys for table columns whose natural order is not the string order.
enum CoreAuditSort {
    /// Numeric key for a dotted IPv4 string so `.9` sorts before `.10`;
    /// unparseable or missing addresses sort last.
    static func ipv4Key(_ ip: String?) -> UInt32 {
        guard let ip else { return .max }
        let octets = ip.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return .max }
        return octets.reduce(0) { ($0 << 8) | $1 }
    }
}

enum CoreAuditLabel {
    /// Human label for a hyphenated script token (`directory-infrastructure` →
    /// `Directory infrastructure`); sentinels become `nil`.
    static func humanized(_ token: String?) -> String? {
        guard let token = Fmt.text(token) else { return nil }
        let words = token
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
