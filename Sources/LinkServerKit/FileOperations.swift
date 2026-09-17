import Foundation
import CryptoKit
import LinkProtocol

public final class FileOperations {
    public let paths: PathPolicy
    private let fm = FileManager.default
    public init(paths: PathPolicy) { self.paths = paths }

    public func handle(_ method: String, _ p: [String: JSONValue]) throws -> JSONValue {
        switch method {
        case "fs.list": return try list(p)
        case "fs.stat": return try metadata(paths.resolve(p.requiredString("path")))
        case "fs.read": return try read(p)
        case "fs.write": return try write(p)
        case "fs.append": return try append(p)
        case "fs.patch": return try patch(p)
        case "fs.mkdir":
            try fm.createDirectory(at: paths.resolve(p.requiredString("path")),
                                   withIntermediateDirectories: p.flag("parents"))
        case "fs.move", "fs.copy":
            let from = try paths.resolve(p.requiredString("source"), allowRoot: false, followFinalLink: method != "fs.move")
            let to = try paths.resolve(p.requiredString("destination"), allowRoot: false)
            // Directory trees can contain links outside the root; only regular-file copies are supported.
            if method == "fs.copy" {
                _ = try paths.regularFile(p.requiredString("source"))
                try fm.copyItem(at: from, to: to)
            } else { try fm.moveItem(at: from, to: to) }
        case "fs.delete":
            let url = try paths.resolve(p.requiredString("path"), allowRoot: false, followFinalLink: false)
            let directory = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory
            if directory, try !p.flag("recursive"), !(try fm.contentsOfDirectory(atPath: url.path)).isEmpty {
                throw RPCError("not_empty", "Set recursive=true to delete a nonempty directory")
            }
            try fm.removeItem(at: url)
        case "fs.hash":
            return .object(["sha256": .string(try hashFile(paths.regularFile(p.requiredString("path"))))])
        case "fs.search": return try FileSearch(paths: paths).search(p)
        default: throw RPCError("unknown_method", method)
        }
        return .object(["ok": .bool(true)])
    }

    public func metadata(_ url: URL) throws -> JSONValue {
        let a = try fm.attributesOfItem(atPath: url.path)
        return .object([
            "path": .string(paths.relative(url)),
            "type": .string((a[.type] as? FileAttributeType)?.rawValue ?? "unknown"),
            "size": .int((a[.size] as? NSNumber)?.int64Value ?? 0),
            "mode": .int((a[.posixPermissions] as? NSNumber)?.int64Value ?? 0),
            "modified": .double((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        ])
    }

    private func list(_ p: [String: JSONValue]) throws -> JSONValue {
        let url = try paths.resolve(p["path"]?.string ?? ".")
        let offset = try p.integer("offset", default: 0, range: 0...10_000)
        let limit = try p.integer("limit", default: 100, range: 1...500)
        guard let enumeration = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                              options: [.skipsSubdirectoryDescendants]) else {
            throw RPCError("io", "Cannot enumerate directory")
        }
        var entries: [URL] = []
        for case let child as URL in enumeration {
            guard entries.count < 10_000 else { throw RPCError("limit", "Directory exceeds 10000 entries; use exec") }
            entries.append(child)
        }
        entries.sort { $0.lastPathComponent < $1.lastPathComponent }
        let page = try entries.dropFirst(offset).prefix(limit).map { try metadata($0) }
        let next = min(entries.count, offset + page.count)
        return .object(["entries": .array(page), "next_offset": next < entries.count ? .int(Int64(next)) : .null])
    }

    private func read(_ p: [String: JSONValue]) throws -> JSONValue {
        let url = try paths.regularFile(p.requiredString("path"))
        let offset = try p.integer("offset", default: 0, range: 0...Int.max)
        let count = try p.integer("length", default: 32_768, range: 1...65_536)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard UInt64(offset) <= size else { throw RPCError("invalid_params", "Offset is past EOF") }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: count) ?? Data()
        return .object(["data": .string(data.base64EncodedString()), "offset": .int(Int64(offset)),
                        "next_offset": .int(Int64(offset + data.count)),
                        "eof": .bool(UInt64(offset + data.count) >= size), "size": .int(Int64(size))])
    }

    public func checkDestination(_ url: URL, _ p: [String: JSONValue]) throws {
        let exists = fm.fileExists(atPath: url.path)
        if exists {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw RPCError("invalid_path", "Destination must be a regular file")
            }
        }
        if let expected = p["expected_sha256"]?.string {
            guard exists, try hashFile(url) == expected else { throw RPCError("conflict", "File hash changed") }
        } else if exists, try !p.flag("overwrite") {
            throw RPCError("exists", "Use expected_sha256 or overwrite=true for an existing file")
        }
    }

    private func write(_ p: [String: JSONValue]) throws -> JSONValue {
        let url = try paths.resolve(p.requiredString("path"), allowRoot: false)
        let data = try p.bytes("data")
        try checkDestination(url, p)
        try atomicWrite(data, to: url)
        return .object(["size": .int(Int64(data.count)), "sha256": .string(sha256(data))])
    }

    private func append(_ p: [String: JSONValue]) throws -> JSONValue {
        let url = try paths.regularFile(p.requiredString("path"))
        let data = try p.bytes("data")
        var conditions = p
        conditions["overwrite"] = .bool(true)
        try checkDestination(url, conditions)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return .object(["size": .int(Int64(offset) + Int64(data.count))])
    }

    private func patch(_ p: [String: JSONValue]) throws -> JSONValue {
        let url = try paths.regularFile(p.requiredString("path"))
        _ = try p.requiredString("expected_sha256")
        try checkDestination(url, p)
        let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= 1_048_576, let edits = p["edits"]?.array, (1...100).contains(edits.count) else {
            throw RPCError("limit", "Patch requires 1–100 edits and a text file of at most 1 MiB")
        }
        var text = try String(contentsOf: url, encoding: .utf8)
        for edit in edits {
            guard let item = edit.object else { throw RPCError("invalid_params", "Each edit must be an object") }
            let old = try item.requiredString("old"), new = try item.requiredString("new")
            guard !old.isEmpty, let range = text.range(of: old), text[range.upperBound...].range(of: old) == nil else {
                throw RPCError("conflict", "Each old text must match exactly once")
            }
            text.replaceSubrange(range, with: new)
            guard text.utf8.count <= 1_048_576 else { throw RPCError("limit", "Patched file exceeds 1 MiB") }
        }
        let data = Data(text.utf8)
        try atomicWrite(data, to: url)
        return .object(["sha256": .string(sha256(data)), "size": .int(Int64(data.count))])
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600
        try data.write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}

public func hashFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 65_536), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
