import Foundation

/// Any JSON value: lets one state message decode section by section.
public enum JSONValue: Sendable, Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
}

extension Dictionary where Key == String, Value == JSONValue {
    func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let value = self[key], value != .null, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(JSONValue.object(self)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Decodes each element on its own, dropping the ones that fail.
    func decodeArray<T: Decodable>(_ type: T.Type, key: String) -> [T] {
        guard case .array(let items)? = self[key] else { return [] }
        return items.compactMap { item in
            guard let data = try? JSONEncoder().encode(item) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }
}

// Lenient scalar decoding: the backend is Python, so numbers may come as floats or strings.
extension KeyedDecodingContainer {
    func decodeInt64(_ key: Key) -> Int64? {
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int64(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int64(s) }
        return nil
    }

    func decodeDouble(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }

    func decodeTopic(_ key: Key) -> TopicID? {
        if let s = try? decodeIfPresent(String.self, forKey: key), s == "main" { return .main }
        return decodeInt64(key).map { TopicID(truncatingIfNeeded: $0) }
    }

    /// Unix seconds (or milliseconds), or ISO 8601.
    func decodeFlexibleDate(_ key: Key) -> Date? {
        if let d = decodeDouble(key) { return Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            let f = ISO8601DateFormatter()
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s)
        }
        return nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
