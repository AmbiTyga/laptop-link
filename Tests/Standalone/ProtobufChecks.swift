import Foundation
import SwiftProtobuf
import LinkProtocol

enum ProtobufChecks {
    static func values() throws {
        let binary = Data((0..<65_536).map { UInt8($0 % 256) })
        let params: [String: JSONValue] = ["path": .string("🛠 file"), "data": .string(binary.base64EncodedString()),
            "min": .int(.min), "max": .int(.max), "large": .int(9_007_199_254_740_993),
            "float": .double(1.25), "null": .null, "false": .bool(false), "empty": .object([:]),
            "list": .array([]), "nested": .array([.object(["yes": .bool(true)])])]
        let request = RPCRequest(id: UUID().uuidString.lowercased(), method: "fs.write", bootID: "boot", params: params)
        let encoded = try ProtobufWire.encode(request), decoded = try ProtobufWire.request(encoded)
        try require(decoded.id == request.id && decoded.bootID == request.bootID, "Identity spelling changed")
        try require(decoded.params == params, "Protobuf values lost data or integer precision")
        let typed = try Ble_Wire_V2_Request(serializedBytes: encoded)
        try require(typed.params.fields["data"]?.bytesValue == binary, "File payload still uses base64 on the wire")
        let environment = RPCRequest(method: "exec.start", params: ["env": .object(["data": .string("aGVsbG8=")])])
        let env = try Ble_Wire_V2_Request(serializedBytes: ProtobufWire.encode(environment))
        try require(env.params.fields["env"]?.objectValue.fields["data"]?.stringValue == "aGVsbG8=", "Environment changed type")
        let response = RPCResponse(id: request.id, bootID: "boot", result: .array([
            .object(["stdout": .object(["data": .string(binary.base64EncodedString())])])]))
        try require(try ProtobufWire.response(ProtobufWire.encode(response)).result == response.result, "Output bytes lost")
        let failed = RPCResponse(id: request.id, bootID: "boot", error: RPCError("failed", "Unicode 🛠"))
        try require(try ProtobufWire.response(ProtobufWire.encode(failed)).error == failed.error, "Error changed")
        let unknown = encoded + Data([0xA0, 0x06, 0x01]) // Future field 100, varint 1.
        try require(try ProtobufWire.request(unknown).params == params, "Unknown field broke decoding")
    }

    static func validation() throws {
        try rejects { _ = try ProtobufWire.request(Data([0x80])) }
        try rejects { _ = try ProtobufWire.envelope(Data(repeating: 0, count: 262_145)) }
        var missing = Ble_Wire_V2_Request(); missing.version = 1; missing.method = "fs.write"
        try rejects { _ = try ProtobufWire.request(missing.serializedData()) }
        var deep = JSONValue.null
        for _ in 0..<30 { deep = .array([deep]) }
        try rejects { _ = try ProtobufWire.encode(RPCRequest(method: "test", params: ["deep": deep])) }
        try rejects { _ = try ProtobufWire.encode(RPCRequest(method: "test", params: ["nan": .double(.nan)])) }
        try rejects { _ = try ProtobufWire.encode(Envelope(type: "data", payload: Data(repeating: 1, count: 16))) }
        let zero = Envelope(type: "data", sequence: 0, payload: Data(repeating: 1, count: 16))
        try require(try ProtobufWire.envelope(ProtobufWire.encode(zero)).sequence == 0, "Zero sequence lost presence")
        var wrong = Ble_Wire_V2_Envelope(); wrong.wireVersion = 99; wrong.kind = .hello; wrong.nonce = Data(repeating: 1, count: 32)
        try rejects { _ = try ProtobufWire.envelope(wrong.serializedData()) }
    }

    static func security() throws {
        for format in [WireFormat.json, .protobuf] {
            let key = try ChannelCrypto.random()
            let client = try ClientHandshake(key: key, format: format), server = ServerHandshake(key: key, format: format)
            let hello = try format.decodeEnvelope(format.encodeEnvelope(client.hello))
            let challenge = try format.decodeEnvelope(format.encodeEnvelope(server.receive(hello)))
            let auth = try format.decodeEnvelope(format.encodeEnvelope(client.authenticate(challenge)))
            let ready = try format.decodeEnvelope(format.encodeEnvelope(server.receive(auth)))
            guard let c = client.channel, let s = server.channel else { throw CheckFailure("Missing channels") }
            try require(try c.open(ready) == Data("ready".utf8), "Handshake failed")
            let request = RPCRequest(method: "server.info")
            let frame = try FrameDecoder.encode(format.encodeEnvelope(c.seal(format.encodeRequest(request))))
            var decoder = FrameDecoder(), frames: [Data] = []
            for start in stride(from: 0, to: frame.count, by: 20) {
                frames += try decoder.append(frame.subdata(in: start..<min(start + 20, frame.count)))
            }
            let encrypted = try format.decodeEnvelope(frames[0])
            try require(try format.decodeRequest(s.open(encrypted)).id == request.id, "Fragmented request failed")
            try rejects { _ = try s.open(encrypted) }
            var tampered = try c.seal(Data("private".utf8))
            guard let index = tampered.payload?.startIndex else { throw CheckFailure("Missing ciphertext") }
            tampered.payload![index] ^= 1
            try rejects { _ = try s.open(tampered) }
            let opposite: WireFormat = format == .json ? .protobuf : .json
            let mismatch = ServerHandshake(key: key, format: opposite)
            let fresh = try ClientHandshake(key: key, format: format)
            try rejects { _ = try fresh.authenticate(mismatch.receive(fresh.hello)) }
        }
    }

    static func sizes() throws {
        let raw = Data((0..<65_536).map { UInt8($0 % 251) })
        let request = RPCRequest(method: "upload.chunk", bootID: UUID().uuidString,
                                 params: ["upload_id": .string(UUID().uuidString), "offset": .int(0),
                                          "data": .string(raw.base64EncodedString())])
        var sizes: [WireFormat: Int] = [:]
        for format in [WireFormat.json, .protobuf] {
            let key = Data(repeating: 1, count: 32)
            let transcript = try ChannelCrypto.transcript(client: Data(repeating: 2, count: 32),
                                                          server: Data(repeating: 3, count: 32), format: format)
            let channel = try SecureChannel(key: key, transcript: transcript, server: false, format: format)
            sizes[format] = try FrameDecoder.encode(format.encodeEnvelope(channel.seal(format.encodeRequest(request)))).count
        }
        let json = sizes[.json]!, protobuf = sizes[.protobuf]!
        try require(protobuf < 66_000 && protobuf * 100 < json * 58, "Binary payload size regression")
        print("SIZE: 65536-byte upload chunk, encrypted/framed JSON=\(json), Protobuf=\(protobuf), saved=\(String(format: "%.1f", 100 * (1 - Double(protobuf) / Double(json))))%")
    }
}
