import Foundation

/// JSON stays at the local CLI/MCP boundary; only specified data fields become raw wire bytes.
enum ProtobufValues {
    static func encode(_ value: JSONValue, binaryData: Bool = false, depth: Int = 0) throws -> Ble_Wire_V2_Value {
        guard depth < 24 else { throw RPCError("limit", "Value nesting exceeds 24 levels") }
        var result = Ble_Wire_V2_Value()
        switch value {
        case .string(let v): result.stringValue = v
        case .int(let v): result.integerValue = v
        case .double(let v):
            guard v.isFinite else { throw RPCError("invalid_params", "Non-finite number") }
            result.doubleValue = v
        case .bool(let v): result.boolValue = v
        case .null: result.nullValue = .value
        case .array(let values):
            result.listValue.values = try values.map { try encode($0, binaryData: binaryData, depth: depth + 1) }
        case .object(let fields):
            for (key, value) in fields {
                if binaryData, key == "data", let text = value.string, let bytes = Data(base64Encoded: text),
                   bytes.base64EncodedString() == text {
                    var field = Ble_Wire_V2_Value(); field.bytesValue = bytes
                    result.objectValue.fields[key] = field
                } else {
                    result.objectValue.fields[key] = try encode(value, binaryData: binaryData, depth: depth + 1)
                }
            }
            // Preserve an empty object's oneof presence.
            if fields.isEmpty { result.objectValue = Ble_Wire_V2_Object() }
        }
        return result
    }

    static func requestObject(_ request: RPCRequest) throws -> Ble_Wire_V2_Object {
        var object = try encode(.object(request.params)).objectValue
        if ["fs.write", "fs.append", "upload.chunk"].contains(request.method),
           let text = request.params["data"]?.string, let bytes = Data(base64Encoded: text),
           bytes.base64EncodedString() == text {
            var field = Ble_Wire_V2_Value(); field.bytesValue = bytes
            object.fields["data"] = field
        }
        return object
    }

    static func decode(_ value: Ble_Wire_V2_Value, depth: Int = 0) throws -> JSONValue {
        guard depth < 24 else { throw RPCError("limit", "Value nesting exceeds 24 levels") }
        switch value.kind {
        case .stringValue(let v): return .string(v)
        case .integerValue(let v): return .int(v)
        case .doubleValue(let v):
            guard v.isFinite else { throw RPCError("invalid_request", "Non-finite number") }
            return .double(v)
        case .boolValue(let v): return .bool(v)
        case .bytesValue(let v): return .string(v.base64EncodedString())
        case .objectValue(let v):
            return .object(try v.fields.mapValues { try decode($0, depth: depth + 1) })
        case .listValue(let v): return .array(try v.values.map { try decode($0, depth: depth + 1) })
        case .nullValue(.value): return .null
        default: throw RPCError("invalid_request", "Missing or unknown value kind")
        }
    }
}
