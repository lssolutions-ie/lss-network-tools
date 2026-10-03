import Foundation

/// A number the script may have written as a JSON number, a numeric string
/// (`"91.10"`, `"0"`), or `null` (research 03, hazards 9–10). Missing keys
/// decode as `nil` thanks to the `KeyedDecodingContainer` overload below.
///
/// ```swift
/// struct SpeedTestServer: Decodable { @Lenient var pingMs: Double? }
/// ```
@propertyWrapper
public struct Lenient: Decodable, Sendable, Hashable {
    public var wrappedValue: Double?

    public init(wrappedValue: Double?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else if let number = try? container.decode(Double.self) {
            wrappedValue = number
        } else if let text = try? container.decode(String.self) {
            wrappedValue = Lenient.parse(text)
        } else if let flag = try? container.decode(Bool.self) {
            wrappedValue = flag ? 1 : 0
        } else {
            wrappedValue = nil
        }
    }

    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let value = Double(trimmed) { return value }
        // "12,5" or "91.10 Mbps" style leftovers
        let cleaned = trimmed.replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.-").inverted)
            .first { !$0.isEmpty } ?? ""
        return Double(cleaned)
    }
}

/// Array of lenient numbers, e.g. `response_times_ms: [12.4, null, "15"]`.
@propertyWrapper
public struct LenientArray: Decodable, Sendable, Hashable {
    public var wrappedValue: [Double?]?

    public init(wrappedValue: [Double?]?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else {
            let items = try container.decode([Lenient].self)
            wrappedValue = items.map(\.wrappedValue)
        }
    }
}

/// An integer-or-string value such as `vlan` ids or probe counts.
@propertyWrapper
public struct LenientInt: Decodable, Sendable, Hashable {
    public var wrappedValue: Int?

    public init(wrappedValue: Int?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let lenient = try Lenient(from: decoder)
        if let value = lenient.wrappedValue, value.isFinite {
            wrappedValue = Int(value.rounded())
        } else {
            wrappedValue = nil
        }
    }
}

/// A string that may have been written as a number (`"channel": 36` vs `"36"`).
@propertyWrapper
public struct LenientString: Decodable, Sendable, Hashable {
    public var wrappedValue: String?

    public init(wrappedValue: String?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else if let text = try? container.decode(String.self) {
            wrappedValue = text
        } else if let number = try? container.decode(Double.self) {
            wrappedValue = number == number.rounded() ? String(Int(number)) : String(number)
        } else if let flag = try? container.decode(Bool.self) {
            wrappedValue = flag ? "true" : "false"
        } else {
            wrappedValue = nil
        }
    }
}

// Missing keys → nil instead of `keyNotFound`.
public extension KeyedDecodingContainer {
    func decode(_ type: Lenient.Type, forKey key: Key) throws -> Lenient {
        try decodeIfPresent(type, forKey: key) ?? Lenient(wrappedValue: nil)
    }

    func decode(_ type: LenientArray.Type, forKey key: Key) throws -> LenientArray {
        try decodeIfPresent(type, forKey: key) ?? LenientArray(wrappedValue: nil)
    }

    func decode(_ type: LenientInt.Type, forKey key: Key) throws -> LenientInt {
        try decodeIfPresent(type, forKey: key) ?? LenientInt(wrappedValue: nil)
    }

    func decode(_ type: LenientString.Type, forKey key: Key) throws -> LenientString {
        try decodeIfPresent(type, forKey: key) ?? LenientString(wrappedValue: nil)
    }
}
