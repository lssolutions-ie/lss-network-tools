import Foundation

/// Decoder configuration shared by every model: snake_case keys as written by
/// jq, no automatic date decoding (the two date formats are parsed by hand).
public enum LSSJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// Decodes `T` from a file, surfacing the first decoding problem as text.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    /// Parses `manifest.generated_at` (`dd-MM-yyyy HH:mm`, local time) and the
    /// run directory's `dd-mm-yyyy` date stamp.
    public static func parseLocalDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for format in ["dd-MM-yyyy HH:mm", "dd-MM-yyyy HH:mm:ss", "dd-MM-yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Parses the wireless survey's ISO-8601 UTC timestamps.
    public static func parseISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// Human-readable description of a decoding error (path + reason).
    public static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return String(describing: error) }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "<root>" : keys.joined(separator: ".")
        }
        switch decodingError {
        case .typeMismatch(let type, let context):
            return "\(path(context)): expected \(type) — \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "\(path(context)): missing \(type) — \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "\(path(context)): key '\(key.stringValue)' not found"
        case .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}

/// Sentinel strings the script writes instead of null (`"unknown"`, `"--"`, `""`).
public enum Sentinel {
    public static let values: Set<String> = ["", "unknown", "--", "n/a", "N/A", "null", "none"]

    public static func isSentinel(_ text: String?) -> Bool {
        guard let text else { return true }
        return values.contains(text.trimmingCharacters(in: .whitespaces))
    }

    /// Returns `nil` for sentinels so views can show a dash.
    public static func value(_ text: String?) -> String? {
        isSentinel(text) ? nil : text
    }
}

/// Natural ("device-2" before "device-10") ordering helpers.
public enum NaturalSort {
    /// The N in `<stem>-device-N.json`, if any.
    public static func deviceIndex(of fileName: String) -> Int? {
        guard let range = fileName.range(of: "-device-([0-9]+)\\.json$", options: .regularExpression) else { return nil }
        let match = fileName[range]
        let digits = match.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }

    /// Sorts file names by device index (non-indexed names first), then by name.
    public static func sortFileNames(_ names: [String]) -> [String] {
        names.sorted { lhs, rhs in
            let li = deviceIndex(of: lhs) ?? -1
            let ri = deviceIndex(of: rhs) ?? -1
            if li != ri { return li < ri }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}
