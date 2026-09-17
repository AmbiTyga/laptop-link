import Foundation

/// Serialization is fixed for the lifetime of an authenticated connection.
public enum WireFormat: String, Sendable {
    case json, protobuf

    public var domain: String { self == .protobuf ? "ble-connection/v2/" : "ble-connection/v1/" }

    public static func detect(_ firstFrame: Data) throws -> WireFormat {
        guard let first = firstFrame.first(where: { ![9, 10, 13, 32].contains($0) }) else {
            throw RPCError("protocol", "Empty envelope")
        }
        return first == 123 ? .json : .protobuf
    }

    public func encodeEnvelope(_ envelope: Envelope) throws -> Data {
        try self == .json ? WireJSON.encode(envelope) : ProtobufWire.encode(envelope)
    }
    public func decodeEnvelope(_ data: Data) throws -> Envelope {
        try self == .json ? WireJSON.decode(Envelope.self, from: data) : ProtobufWire.envelope(data)
    }
    public func encodeRequest(_ request: RPCRequest) throws -> Data {
        try self == .json ? WireJSON.encode(request) : ProtobufWire.encode(request)
    }
    public func decodeRequest(_ data: Data) throws -> RPCRequest {
        try self == .json ? WireJSON.decode(RPCRequest.self, from: data) : ProtobufWire.request(data)
    }
    public func encodeResponse(_ response: RPCResponse) throws -> Data {
        try self == .json ? WireJSON.encode(response) : ProtobufWire.encode(response)
    }
    public func decodeResponse(_ data: Data) throws -> RPCResponse {
        try self == .json ? WireJSON.decode(RPCResponse.self, from: data) : ProtobufWire.response(data)
    }
}
