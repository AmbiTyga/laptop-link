import Foundation
import LinkProtocol
import Darwin

/// Owned by a CommandJob's serial queue. Pipes are always drained, even after the disk cap.
final class OutputSpool {
    let url: URL
    private let handle: FileHandle
    private let cap: Int
    private(set) var bytes: Int = 0
    private(set) var discarded: Int64 = 0
    private(set) var error: String?

    init(url: URL, cap: Int) throws {
        self.url = url; self.cap = cap
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RPCError("io", "Cannot create command output file")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle.close() }

    func append(_ data: Data) {
        let keep = error == nil ? min(data.count, cap - bytes) : 0
        do {
            if keep > 0 { try handle.write(contentsOf: data.prefix(keep)); bytes += keep }
            discarded += Int64(data.count - keep)
        } catch {
            self.error = error.localizedDescription
            discarded += Int64(data.count)
        }
    }

    func read(offset: Int, count: Int) throws -> JSONValue {
        guard offset <= bytes else { throw RPCError("invalid_params", "Output cursor is past the retained output") }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(offset))
        let data = try reader.read(upToCount: min(count, bytes - offset)) ?? Data()
        return .object(["data": .string(data.base64EncodedString()), "next_offset": .int(Int64(offset + data.count)),
                        "retained_bytes": .int(Int64(bytes)), "discarded_bytes": .int(discarded),
                        "error": error.map(JSONValue.string) ?? .null])
    }
}
