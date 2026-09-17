import Foundation
import LinkProtocol

/// A bounded rolling byte history with absolute cursors, owned by the session queue.
final class TerminalOutput {
    private var data = Data()
    private let cap: Int
    private var first: Int64 = 0
    init(cap: Int) { self.cap = cap }
    func append(_ bytes: Data) {
        data.append(bytes)
        if data.count > cap {
            let dropped = data.count - cap
            data.removeFirst(dropped); first += Int64(dropped)
        }
    }
    func read(offset: Int64, count: Int) throws -> JSONValue {
        let end = first + Int64(data.count)
        guard offset >= 0, offset <= end else { throw RPCError("invalid_params", "Terminal cursor exceeds output") }
        let start = max(offset, first), skip = Int(start - first)
        let bytes = Data(data.dropFirst(skip).prefix(count))
        return .object(["data": .string(bytes.base64EncodedString()), "offset": .int(start),
                        "next_offset": .int(start + Int64(bytes.count)), "first_offset": .int(first),
                        "total_bytes": .int(end), "truncated": .bool(offset < first)])
    }
}
