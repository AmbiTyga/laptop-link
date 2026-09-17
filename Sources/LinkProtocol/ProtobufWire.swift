import Foundation
import SwiftProtobuf

/// Binary wire v2. Typed metadata plus lossless values; no JSON or base64 envelope on BLE.
public enum ProtobufWire {
    private static func decode<T: SwiftProtobuf.Message>(_ type: T.Type, _ data: Data, maximum: Int) throws -> T {
        guard !data.isEmpty, data.count <= maximum else { throw RPCError("limit", "Invalid Protobuf size") }
        var options = BinaryDecodingOptions(); options.messageDepthLimit = 64
        return try T(serializedBytes: data, options: options)
    }

    public static func encode(_ request: RPCRequest) throws -> Data {
        guard request.version == 1 else { throw RPCError("protocol", "Unsupported RPC version") }
        var message = Ble_Wire_V2_Request()
        message.version = 1; message.id = request.id; message.method = request.method
        if let boot = request.bootID { message.bootID = boot }
        message.params = try ProtobufValues.requestObject(request)
        return try bounded(message, maximum: 131_072)
    }

    public static func request(_ data: Data) throws -> RPCRequest {
        let message = try decode(Ble_Wire_V2_Request.self, data, maximum: 131_072)
        guard message.version == 1, UUID(uuidString: message.id) != nil, !message.method.isEmpty, message.hasParams else {
            throw RPCError("invalid_request", "Missing request metadata")
        }
        var value = Ble_Wire_V2_Value(); value.objectValue = message.params
        return RPCRequest(id: message.id, method: message.method,
                          bootID: message.hasBootID ? message.bootID : nil,
                          params: try ProtobufValues.decode(value).object ?? [:])
    }

    public static func encode(_ response: RPCResponse) throws -> Data {
        var message = Ble_Wire_V2_Response()
        message.version = 1; message.id = response.id; message.bootID = response.bootID
        if let error = response.error, response.result == nil {
            message.error.code = error.code; message.error.message = error.message
        } else if let result = response.result, response.error == nil {
            message.result = try ProtobufValues.encode(result, binaryData: true)
        } else { throw RPCError("protocol", "Response requires exactly one outcome") }
        return try bounded(message, maximum: 131_072)
    }

    public static func response(_ data: Data) throws -> RPCResponse {
        let message = try decode(Ble_Wire_V2_Response.self, data, maximum: 131_072)
        guard message.version == 1, !message.bootID.isEmpty else { throw RPCError("protocol", "Invalid response") }
        switch message.outcome {
        case .result(let value):
            return RPCResponse(id: message.id, bootID: message.bootID, result: try ProtobufValues.decode(value))
        case .error(let error):
            return RPCResponse(id: message.id, bootID: message.bootID, error: RPCError(error.code, error.message))
        case nil: throw RPCError("protocol", "Missing response outcome")
        }
    }

    public static func encode(_ envelope: Envelope) throws -> Data {
        var message = Ble_Wire_V2_Envelope(); message.wireVersion = 2
        switch envelope.type {
        case "hello": message.kind = .hello
        case "challenge": message.kind = .challenge
        case "authenticate": message.kind = .authenticate
        case "data": message.kind = .data
        default: throw RPCError("protocol", "Unknown envelope type")
        }
        message.nonce = envelope.nonce ?? Data(); message.proof = envelope.proof ?? Data()
        message.payload = envelope.payload ?? Data()
        if let sequence = envelope.sequence { message.sequence = sequence }
        try validate(message)
        return try bounded(message, maximum: FrameDecoder.maximum)
    }

    public static func envelope(_ data: Data) throws -> Envelope {
        let message = try decode(Ble_Wire_V2_Envelope.self, data, maximum: FrameDecoder.maximum)
        try validate(message)
        let type: String
        switch message.kind {
        case .hello: type = "hello"
        case .challenge: type = "challenge"
        case .authenticate: type = "authenticate"
        case .data: type = "data"
        default: throw RPCError("protocol", "Unknown envelope kind")
        }
        return Envelope(type: type, nonce: message.nonce.isEmpty ? nil : message.nonce,
                        proof: message.proof.isEmpty ? nil : message.proof,
                        sequence: message.hasSequence ? message.sequence : nil,
                        payload: message.payload.isEmpty ? nil : message.payload)
    }

    private static func validate(_ message: Ble_Wire_V2_Envelope) throws {
        guard message.wireVersion == 2 else { throw RPCError("protocol", "Expected wire version 2") }
        let valid: Bool
        switch message.kind {
        case .hello:
            valid = message.nonce.count == 32 && message.proof.isEmpty && !message.hasSequence && message.payload.isEmpty
        case .challenge:
            valid = message.nonce.count == 32 && message.proof.count == 32 && !message.hasSequence && message.payload.isEmpty
        case .authenticate:
            valid = message.nonce.isEmpty && message.proof.count == 32 && !message.hasSequence && message.payload.isEmpty
        case .data:
            valid = message.nonce.isEmpty && message.proof.isEmpty && message.hasSequence && message.payload.count >= 16
        default: valid = false
        }
        guard valid else { throw RPCError("protocol", "Invalid envelope fields") }
    }

    private static func bounded<T: SwiftProtobuf.Message>(_ message: T, maximum: Int) throws -> Data {
        let data = try message.serializedData()
        guard data.count <= maximum else { throw RPCError("limit", "Protobuf message exceeds limit") }
        return data
    }
}
