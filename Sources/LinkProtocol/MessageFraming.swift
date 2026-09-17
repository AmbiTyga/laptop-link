import Foundation

/// Four-byte network-order length followed by one JSON envelope. GATT chunks can split anywhere.
public struct FrameDecoder {
    public static let maximum = 262_144
    private var buffer = Data()
    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        guard bytes.count <= Self.maximum + 4, buffer.count + bytes.count <= 2 * (Self.maximum + 4) else {
            throw RPCError("frame_too_large", "Receive buffer limit exceeded")
        }
        buffer.append(bytes)
        var messages: [Data] = []
        while buffer.count >= 4 {
            let size = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, size <= Self.maximum else { throw RPCError("invalid_frame", "Invalid frame length") }
            guard buffer.count >= size + 4 else { break }
            messages.append(Data(buffer.dropFirst(4).prefix(size)))
            buffer = Data(buffer.dropFirst(size + 4))
        }
        return messages
    }

    public static func encode(_ bytes: Data) throws -> Data {
        guard !bytes.isEmpty, bytes.count <= maximum else { throw RPCError("frame_too_large", "Invalid message size") }
        var size = UInt32(bytes.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(bytes)
        return frame
    }
}
