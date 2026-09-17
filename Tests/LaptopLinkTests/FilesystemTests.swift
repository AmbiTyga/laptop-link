import XCTest
import Foundation
import LinkProtocol
import LinkServerKit

final class FilesystemTests: XCTestCase {
    func testWriteReadPatchConflictAndDeduplication() throws {
        let f = try ServerFixture()
        let data = Data("hello world".utf8)
        _ = try f.result("fs.write", ["path": .string("sample.txt"), "data": .string(data.base64EncodedString())])
        let read = try f.result("fs.read", ["path": .string("sample.txt"), "offset": .int(6), "length": .int(5)])
        XCTAssertEqual(read["data"]?.string, Data("world".utf8).base64EncodedString())
        XCTAssertEqual(read["eof"], .bool(true))
        XCTAssertEqual(f.call("fs.write", ["path": .string("sample.txt"), "data": .string("")]).error?.code, "exists")
        let edits: JSONValue = .array([.object(["old": .string("world"), "new": .string("Mac")])])
        XCTAssertEqual(f.call("fs.patch", ["path": .string("sample.txt"), "expected_sha256": .string("wrong"), "edits": edits]).error?.code, "conflict")
        _ = try f.result("fs.patch", ["path": .string("sample.txt"), "expected_sha256": .string(sha256(data)), "edits": edits])
        let id = UUID().uuidString, params: [String: JSONValue] = ["path": .string("sample.txt"), "data": .string("IQ==")]
        XCTAssertNil(f.call("fs.append", params, id: id).error)
        XCTAssertNil(f.call("fs.append", params, id: id).error)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("sample.txt"), encoding: .utf8), "hello Mac!")
        XCTAssertEqual(f.call("fs.delete", ["path": .string("sample.txt")], id: id).error?.code, "id_conflict")
    }

    func testPathEscapesSymlinksAndRootDeletion() throws {
        let f = try ServerFixture()
        XCTAssertEqual(f.call("fs.stat", ["path": .string("../")]).error?.code, "path_denied")
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("escape"), withDestinationURL: f.directory)
        XCTAssertEqual(f.call("fs.read", ["path": .string("escape/file")]).error?.code, "path_denied")
        XCTAssertEqual(f.call("fs.delete", ["path": .string("."), "recursive": .bool(true)]).error?.code, "path_denied")
        let stale = f.router.handle(RPCRequest(method: "fs.mkdir", bootID: "old-boot", params: ["path": .string("oops")]))
        XCTAssertEqual(stale.error?.code, "server_changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("oops").path))
    }

    func testChunkedUploadAndHash() throws {
        let f = try ServerFixture(), data = Data((0..<150_000).map { UInt8($0 % 251) })
        let begin = try f.result("upload.begin", ["path": .string("binary"), "size": .int(Int64(data.count)), "sha256": .string(sha256(data))])
        let id = try XCTUnwrap(begin["upload_id"]?.string)
        XCTAssertEqual(f.call("upload.chunk", ["upload_id": .string(id), "offset": .int(1), "data": .string("YQ==")]).error?.code, "conflict")
        for offset in stride(from: 0, to: data.count, by: 65_536) {
            _ = try f.result("upload.chunk", ["upload_id": .string(id), "offset": .int(Int64(offset)),
                                               "data": .string(data.subdata(in: offset..<min(data.count, offset + 65_536)).base64EncodedString())])
        }
        _ = try f.result("upload.commit", ["upload_id": .string(id)])
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("binary")), data)
        XCTAssertEqual(try f.result("fs.hash", ["path": .string("binary")])["sha256"], .string(sha256(data)))
    }

    func testDirectorySearchMoveCopyAndDelete() throws {
        let f = try ServerFixture()
        _ = try f.result("fs.mkdir", ["path": .string("src")])
        _ = try f.result("fs.write", ["path": .string("src/a.txt"), "data": .string(Data("first\nneedle\nlast".utf8).base64EncodedString())])
        let search = try f.result("fs.search", ["query": .string("needle"), "content": .bool(true)])
        XCTAssertEqual(search["matches"]?.array?.first?.object?["line"], .int(2))
        _ = try f.result("fs.copy", ["source": .string("src/a.txt"), "destination": .string("b.txt")])
        _ = try f.result("fs.move", ["source": .string("b.txt"), "destination": .string("c.txt")])
        let list = try f.result("fs.list")
        XCTAssertEqual(list["entries"]?.array?.count, 2)
        XCTAssertEqual(f.call("fs.delete", ["path": .string("src")]).error?.code, "not_empty")
        _ = try f.result("fs.delete", ["path": .string("src"), "recursive": .bool(true)])
    }
}
