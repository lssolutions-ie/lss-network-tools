import SwiftUI
import LSSCore

// Shared building blocks for the per-task detail views. Keep the look
// consistent: a titled card of label/value rows, status badges, warning lists
// and number formatting. Views in RunBrowser/TaskDetail/ compose these.

/// A card with a title and label/value rows. Pass `nil` values to show a dash.
struct KeyValueGroup: View {
    let title: String?
    let rows: [(label: String, value: String?)]

    init(_ title: String? = nil, rows: [(label: String, value: String?)]) {
        self.title = title
        self.rows = rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.headline)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(row.value ?? "—")
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Titled container for tables and charts.
struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Coloured status pill.
struct StatusBadge: View {
    let status: TaskStatus

    var body: some View {
        Label(status.description, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .success: .green
        case .completedWithWarnings: .orange
        case .failed: .red
        case .skipped: .gray
        case .other: .blue
        }
    }

    private var symbol: String {
        switch status {
        case .success: "checkmark.circle.fill"
        case .completedWithWarnings: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "minus.circle.fill"
        case .other: "questionmark.circle.fill"
        }
    }
}

/// Yes/No pill for boolean indicators; `highlightTrue` makes a true value red.
struct FlagBadge: View {
    let label: String
    let value: Bool?
    var highlightTrue = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: value == true ? (highlightTrue ? "exclamationmark.circle.fill" : "checkmark.circle.fill") : "circle")
                .foregroundStyle(value == true ? (highlightTrue ? .red : .green) : .secondary)
            Text(label)
        }
        .font(.callout)
    }
}

/// Envelope summary shown above every task: status, error and warnings.
struct EnvelopeHeader: View {
    let envelope: TaskEnvelope

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusBadge(status: envelope.effectiveStatus)
                if let reason = envelope.skipReason {
                    Text(reason.replacingOccurrences(of: "_", with: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let message = envelope.skipMessage {
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = envelope.error, error.code != nil || error.message != nil {
                Label {
                    VStack(alignment: .leading) {
                        if let code = error.code { Text(code).font(.system(.caption, design: .monospaced)) }
                        if let message = error.message { Text(message) }
                    }
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !envelope.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(envelope.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Number formatting used by every task view.
enum Fmt {
    static func ms(_ value: Double?) -> String? {
        guard let value else { return nil }
        return value == value.rounded() ? "\(Int(value)) ms" : String(format: "%.2f ms", value)
    }

    static func mbps(_ value: Double?) -> String? {
        guard let value else { return nil }
        return String(format: "%.2f Mbps", value)
    }

    static func percent(_ value: Double?) -> String? {
        guard let value else { return nil }
        return value == value.rounded() ? "\(Int(value)) %" : String(format: "%.1f %%", value)
    }

    static func int(_ value: Int?) -> String? {
        value.map(String.init)
    }

    static func number(_ value: Double?) -> String? {
        guard let value else { return nil }
        return value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(format: "%.2f", value)
    }

    static func yesNo(_ value: Bool?) -> String? {
        guard let value else { return nil }
        return value ? "Yes" : "No"
    }

    static func list(_ values: [String]?) -> String? {
        guard let values, !values.isEmpty else { return nil }
        return values.joined(separator: ", ")
    }

    static func ports(_ values: [Int]?) -> String? {
        guard let values, !values.isEmpty else { return nil }
        return values.map(String.init).joined(separator: ", ")
    }

    /// Sentinel-aware text (`"unknown"`, `"--"`, `""` → nil).
    static func text(_ value: String?) -> String? {
        Sentinel.value(value)
    }
}

/// Pretty-printed JSON in a monospaced, selectable scroll view.
struct RawJSONView: View {
    let json: JSONValue?

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(json?.prettyPrinted() ?? "{}")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
