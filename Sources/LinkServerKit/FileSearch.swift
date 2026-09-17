import Foundation
import LinkProtocol

struct FileSearch {
    let paths: PathPolicy

    func search(_ p: [String: JSONValue]) throws -> JSONValue {
        let base = try paths.resolve(p["path"]?.string ?? ".")
        let query = try p.requiredString("query")
        let content = try p.flag("content")
        let limit = try p.integer("limit", default: 100, range: 1...500)
        guard !query.isEmpty, query.utf8.count <= 4096 else { throw RPCError("invalid_params", "Invalid search query") }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let iterator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys) else {
            throw RPCError("io", "Cannot enumerate search directory")
        }
        var matches: [JSONValue] = [], visited = 0, skipped = 0
        var truncated = false
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        for case let url as URL in iterator {
            visited += 1
            if visited > 10_000 || matches.count >= limit || ProcessInfo.processInfo.systemUptime > deadline {
                truncated = true; break
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else {
                iterator.skipDescendants(); skipped += 1; continue
            }
            guard (try? paths.resolve(url.path)) != nil else { iterator.skipDescendants(); skipped += 1; continue }
            if !content {
                if url.lastPathComponent.contains(query) { matches.append(.object(["path": .string(paths.relative(url))])) }
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard let size = values.fileSize, size <= 1_048_576,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { skipped += 1; continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains(query) else { continue }
                matches.append(.object(["path": .string(paths.relative(url)), "line": .int(Int64(index + 1)),
                                        "text": .string(String(line.prefix(200)))]))
                if matches.count >= limit { truncated = true; break }
            }
        }
        return .object(["matches": .array(matches), "truncated": .bool(truncated), "skipped": .int(Int64(skipped))])
    }
}
