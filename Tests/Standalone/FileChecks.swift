import Foundation
import LinkProtocol

enum FileChecks {
    static func files() throws {
        let f = try RemoteFixture(), original = Data("hello world".utf8)
        try f.result("fs.write", ["path": .string("file"), "data": .string(original.base64EncodedString())])
        let read = try f.result("fs.read", ["path": .string("file"), "offset": .int(6), "length": .int(5)])
        try require(read["data"] == .string(Data("world".utf8).base64EncodedString()), "Ranged read mismatch")
        try require(try f.result("fs.hash", ["path": .string("file")])["sha256"] == .string(sha256(original)), "Hash mismatch")
        let edits: JSONValue = .array([.object(["old": .string("world"), "new": .string("Mac")])])
        try require(try f.call("fs.patch", ["path": .string("file"), "expected_sha256": .string("wrong"), "edits": edits]).error?.code == "conflict", "Stale edit accepted")
        try f.result("fs.patch", ["path": .string("file"), "expected_sha256": .string(sha256(original)), "edits": edits])
        let id = UUID().uuidString, p: [String: JSONValue] = ["path": .string("file"), "data": .string("IQ==")]
        try require(try f.call("fs.append", p, id: id).error == nil, "Append failed")
        try require(try f.call("fs.append", p, id: id).error == nil, "Append retry failed")
        try require(try Data(contentsOf: f.root.appendingPathComponent("file")) == Data("hello Mac!".utf8), "Append executed twice")
    }

    static func directories() throws {
        let f = try RemoteFixture()
        try f.result("fs.mkdir", ["path": .string("src")])
        try f.result("fs.write", ["path": .string("src/a.txt"), "data": .string(Data("first\nneedle\nlast".utf8).base64EncodedString())])
        let search = try f.result("fs.search", ["query": .string("needle"), "content": .bool(true)])
        try require(search["matches"]?.array?.first?.object?["line"] == .int(2), "Content search failed")
        try f.result("fs.copy", ["source": .string("src/a.txt"), "destination": .string("b")])
        try f.result("fs.move", ["source": .string("b"), "destination": .string("c")])
        try require(try f.result("fs.list")["entries"]?.array?.count == 2, "Directory listing failed")
        try require(try f.call("fs.delete", ["path": .string("src")]).error?.code == "not_empty", "Nonrecursive deletion accepted")
        try f.result("fs.delete", ["path": .string("src"), "recursive": .bool(true)])
    }

    static func paths() throws {
        let f = try RemoteFixture()
        try require(try f.call("fs.stat", ["path": .string("../")]).error?.code == "path_denied", "Path escape allowed")
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("escape"), withDestinationURL: f.directory)
        try require(try f.call("fs.read", ["path": .string("escape/nonexistent")]).error?.code == "path_denied", "Symlink escape allowed")
        try require(try f.call("fs.delete", ["path": .string("."), "recursive": .bool(true)]).error?.code == "path_denied", "Root deletion allowed")
        let target = f.root.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("link"), withDestinationURL: target)
        try f.result("fs.move", ["source": .string("link"), "destination": .string("moved")])
        try f.result("fs.delete", ["path": .string("moved")])
        try require(try Data(contentsOf: target) == Data("keep".utf8), "Symlink deletion removed its target")
    }

    static func uploads() throws {
        let f = try RemoteFixture(), bytes = Data((0..<150_000).map { UInt8($0 % 251) })
        let id = try f.result("upload.begin", ["path": .string("binary"), "size": .int(Int64(bytes.count)),
                                               "sha256": .string(sha256(bytes))]).requiredString("upload_id")
        try require(try f.call("upload.chunk", ["upload_id": .string(id), "offset": .int(1), "data": .string("YQ==")]).error?.code == "conflict", "Out-of-order upload accepted")
        for offset in stride(from: 0, to: bytes.count, by: 65_536) {
            let chunk = bytes.subdata(in: offset..<min(bytes.count, offset + 65_536))
            try f.result("upload.chunk", ["upload_id": .string(id), "offset": .int(Int64(offset)), "data": .string(chunk.base64EncodedString())])
        }
        try f.result("upload.commit", ["upload_id": .string(id)])
        try require(try Data(contentsOf: f.root.appendingPathComponent("binary")) == bytes, "Upload bytes differ")
        let bad = try f.result("upload.begin", ["path": .string("binary"), "size": .int(3),
                                                "sha256": .string(sha256(Data("new".utf8))), "overwrite": .bool(true)]).requiredString("upload_id")
        try f.result("upload.chunk", ["upload_id": .string(bad), "offset": .int(0), "data": .string(Data("bad".utf8).base64EncodedString())])
        try require(try f.call("upload.commit", ["upload_id": .string(bad)]).error?.code == "checksum", "Bad checksum accepted")
        try require(try Data(contentsOf: f.root.appendingPathComponent("binary")) == bytes, "Failed upload overwrote destination")
    }
}
