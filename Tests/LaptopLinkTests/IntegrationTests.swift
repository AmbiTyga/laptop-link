import XCTest
import Foundation
import LinkProtocol
import LinkServerKit

final class IntegrationTests: XCTestCase {
    func testEncryptedFramedCommandRoundTrip() throws {
        let fixture = try ServerFixture(), key = try ChannelCrypto.random()
        let client = try ClientHandshake(key: key), server = ServerHandshake(key: key)
        let ready = try server.receive(client.authenticate(server.receive(client.hello)))
        let c = try XCTUnwrap(client.channel), s = try XCTUnwrap(server.channel)
        _ = try c.open(ready)
        let request = RPCRequest(method: "exec.start", bootID: fixture.router.bootID,
                                 params: ["shell": .string("printf 'remote-output'; printf 'remote-error' >&2")])
        let encoded = try FrameDecoder.encode(WireJSON.encode(c.seal(WireJSON.encode(request))))
        var decoder = FrameDecoder(), messages: [Data] = []
        for offset in stride(from: 0, to: encoded.count, by: 20) {
            messages += try decoder.append(encoded.subdata(in: offset..<min(encoded.count, offset + 20)))
        }
        let plain = try s.open(WireJSON.decode(Envelope.self, from: XCTUnwrap(messages.first)))
        let response = fixture.router.handle(try WireJSON.decode(RPCRequest.self, from: plain))
        let decrypted = try WireJSON.decode(RPCResponse.self, from: c.open(s.seal(WireJSON.encode(response))))
        let id = try XCTUnwrap(decrypted.result?.object?["job_id"]?.string)
        let end = try fixture.wait(id)
        XCTAssertEqual(try decoded(end, "stdout"), Data("remote-output".utf8))
        XCTAssertEqual(try decoded(end, "stderr"), Data("remote-error".utf8))
    }

    func testDeletingAndMovingSymlinksPreservesTarget() throws {
        let f = try ServerFixture()
        let target = f.root.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("link"), withDestinationURL: target)
        _ = try f.result("fs.move", ["source": .string("link"), "destination": .string("moved")])
        _ = try f.result("fs.delete", ["path": .string("moved")])
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }

    func testFailedUploadNeverReplacesDestination() throws {
        let f = try ServerFixture()
        let target = f.root.appendingPathComponent("keep")
        try Data("old".utf8).write(to: target)
        let begin = try f.result("upload.begin", ["path": .string("keep"), "size": .int(3),
                                                  "sha256": .string(sha256(Data("new".utf8))), "overwrite": .bool(true)])
        let id = try XCTUnwrap(begin["upload_id"]?.string)
        _ = try f.result("upload.chunk", ["upload_id": .string(id), "offset": .int(0), "data": .string(Data("bad".utf8).base64EncodedString())])
        XCTAssertEqual(f.call("upload.commit", ["upload_id": .string(id)]).error?.code, "checksum")
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
    }

    func testOutputCursorFetchesRemainingBytesAfterExit() throws {
        let f = try ServerFixture(), id = try f.start("/usr/bin/yes abc | /usr/bin/head -c 70000")
        _ = try f.wait(id)
        var collected = Data(), offset: Int64 = 0
        while offset < 70_000 {
            let p = try f.result("exec.poll", ["job_id": .string(id), "stdout_offset": .int(offset), "max_bytes": .int(5000)])
            collected.append(try decoded(p, "stdout"))
            offset = try XCTUnwrap(p["stdout"]?.object?["next_offset"]?.int)
        }
        XCTAssertEqual(collected.count, 70_000)
        XCTAssertEqual(String(decoding: collected.prefix(8), as: UTF8.self), "abc\nabc\n")
    }
}
