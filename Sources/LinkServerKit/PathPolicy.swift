import Foundation
import LinkProtocol
import Darwin

public struct PathPolicy: Sendable {
    public let root: URL
    public init(root: String) throws {
        self.root = try Self.canonical(URL(fileURLWithPath: root).standardizedFileURL)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: self.root.path, isDirectory: &directory), directory.boolValue else {
            throw RPCError("configuration", "Configured root must be an existing directory")
        }
    }

    public func resolve(_ path: String, allowRoot: Bool = true, followFinalLink: Bool = true) throws -> URL {
        guard !path.contains("\0"), path.utf8.count <= 4096 else { throw RPCError("invalid_path", "Invalid path") }
        let input = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        let url = try followFinalLink ? Self.canonical(input) :
            Self.canonical(input.deletingLastPathComponent()).appendingPathComponent(input.lastPathComponent)
        let contained = root.path == "/" || url.path == root.path || url.path.hasPrefix(root.path + "/")
        guard contained, allowRoot || url.path != root.path else {
            throw RPCError("path_denied", "Path is outside the configured root or targets the root itself")
        }
        return url
    }

    // Foundation's symlink resolution can leave unresolved prefixes when the leaf doesn't exist.
    // realpath the nearest existing ancestor, then append the missing components.
    private static func canonical(_ input: URL) throws -> URL {
        if let pointer = Darwin.realpath(input.path, nil) {
            defer { free(pointer) }
            return URL(fileURLWithPath: String(cString: pointer))
        }
        guard errno == ENOENT, input.path != "/" else {
            throw RPCError("invalid_path", "Cannot resolve path: \(String(cString: strerror(errno)))")
        }
        return try canonical(input.deletingLastPathComponent()).appendingPathComponent(input.lastPathComponent)
    }

    public func regularFile(_ path: String) throws -> URL {
        let url = try resolve(path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw RPCError("invalid_path", "Expected a regular file") }
        return url
    }

    public func relative(_ url: URL) -> String {
        if url.path == root.path { return "." }
        return String(url.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
    }
}
