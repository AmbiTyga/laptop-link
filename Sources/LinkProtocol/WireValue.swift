import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String)
    case int(Int64), double(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var int: Int64? { if case .int(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.string else { throw RPCError("invalid_params", "\(key) must be a string") }
        return value
    }

    func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = self[key] else { return fallback }
        guard let raw = value.int, let n = Int(exactly: raw), range.contains(n) else {
            throw RPCError("invalid_params", "\(key) must be an integer in \(range)")
        }
        return n
    }

    func flag(_ key: String, default fallback: Bool = false) throws -> Bool {
        guard let value = self[key] else { return fallback }
        guard let result = value.bool else { throw RPCError("invalid_params", "\(key) must be boolean") }
        return result
    }

    func bytes(_ key: String, maximum: Int = 65_536) throws -> Data {
        let value = try requiredString(key)
        guard value.utf8.count <= maximum * 2, let data = Data(base64Encoded: value), data.count <= maximum else {
            throw RPCError("invalid_params", "\(key) must be base64 of at most \(maximum) bytes")
        }
        return data
    }
}
