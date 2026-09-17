import Foundation
import CryptoKit

public struct RPCError: Error, Codable, LocalizedError, Equatable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { "\(code): \(message)" }
}

public struct RPCRequest: Codable, Sendable {
    public var version: Int = 1
    public let id: String
    public let method: String
    public var bootID: String?
    public var params: [String: JSONValue]

    public init(id: String = UUID().uuidString, method: String, bootID: String? = nil,
                params: [String: JSONValue] = [:]) {
        self.id = id; self.method = method; self.bootID = bootID; self.params = params
    }
}

public struct RPCResponse: Codable, Sendable {
    public let version: Int
    public let id: String
    public let bootID: String
    public let result: JSONValue?
    public let error: RPCError?

    public init(id: String, bootID: String, result: JSONValue? = nil, error: RPCError? = nil) {
        self.version = 1; self.id = id; self.bootID = bootID; self.result = result; self.error = error
    }
}

public enum WireJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

public func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
