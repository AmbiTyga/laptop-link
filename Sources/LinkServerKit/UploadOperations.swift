import Foundation
import LinkProtocol
import Darwin

final class UploadOperations {
    private struct Upload {
        let file: URL
        let destination: String
        let size: Int
        let sha: String
        let conditions: [String: JSONValue]
        var offset: Int = 0
        var touched = Date()
    }
    private var uploads: [String: Upload] = [:]
    private let files: FileOperations
    private let directory: URL
    private let maximum: Int

    init(files: FileOperations, directory: URL, maximum: Int) throws {
        self.files = files; self.directory = directory; self.maximum = maximum
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func handle(_ method: String, _ p: [String: JSONValue]) throws -> JSONValue {
        for (id, upload) in uploads where Date().timeIntervalSince(upload.touched) > 3600 {
            try? FileManager.default.removeItem(at: upload.file); uploads.removeValue(forKey: id)
        }
        if method == "upload.begin" { return try begin(p) }
        let id = try p.requiredString("upload_id")
        guard var upload = uploads[id] else { throw RPCError("unknown_upload", "Upload missing, expired, or from a previous server run") }
        switch method {
        case "upload.status": break
        case "upload.chunk":
            let offset = try p.integer("offset", default: 0, range: 0...maximum)
            let data = try p.bytes("data")
            guard offset == upload.offset, !data.isEmpty, data.count <= upload.size - offset else {
                throw RPCError("conflict", "Wrong upload offset or length; query upload.status")
            }
            let handle = try FileHandle(forWritingTo: upload.file)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
            upload.offset += data.count; upload.touched = Date(); uploads[id] = upload
        case "upload.commit":
            guard upload.offset == upload.size, try hashFile(upload.file) == upload.sha else {
                throw RPCError("checksum", "Upload length or SHA-256 does not match")
            }
            let to = try files.paths.resolve(upload.destination, allowRoot: false)
            try files.checkDestination(to, upload.conditions)
            // Stage beside destination so the final rename stays on one filesystem.
            let temporary = to.deletingLastPathComponent().appendingPathComponent(".ble-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: upload.file, to: temporary)
            let mode = (try? FileManager.default.attributesOfItem(atPath: to.path)[.posixPermissions]) ?? 0o600
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
            guard Darwin.rename(temporary.path, to.path) == 0 else { throw RPCError("io", "Atomic rename failed") }
            try? FileManager.default.removeItem(at: upload.file)
            uploads.removeValue(forKey: id)
            return .object(["sha256": .string(upload.sha), "size": .int(Int64(upload.size))])
        case "upload.abort":
            try FileManager.default.removeItem(at: upload.file); uploads.removeValue(forKey: id)
        default: throw RPCError("unknown_method", method)
        }
        return .object(["upload_id": .string(id), "offset": .int(Int64(upload.offset)), "size": .int(Int64(upload.size))])
    }

    private func begin(_ p: [String: JSONValue]) throws -> JSONValue {
        guard uploads.count < 4 else { throw RPCError("limit", "At most four active uploads") }
        let path = try p.requiredString("path"), sha = try p.requiredString("sha256")
        guard sha.count == 64, sha.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RPCError("invalid_params", "sha256 must be 64 lowercase hexadecimal characters")
        }
        let size = try p.integer("size", default: -1, range: 0...maximum)
        guard size >= 0 else { throw RPCError("invalid_params", "size is required") }
        try files.checkDestination(files.paths.resolve(path, allowRoot: false), p)
        let id = UUID().uuidString, file = directory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RPCError("io", "Cannot create upload file")
        }
        uploads[id] = Upload(file: file, destination: path, size: size, sha: sha, conditions: p)
        return .object(["upload_id": .string(id), "offset": .int(0)])
    }
}
