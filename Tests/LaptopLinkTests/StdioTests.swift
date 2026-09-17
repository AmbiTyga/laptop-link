import XCTest
import Foundation
import Darwin
import LinkProtocol
import LinkServerKit

final class StdioTests: XCTestCase {
    func testInteractiveRequestRepliesWithoutWaitingForEOF() throws {
        let f = try ServerFixture()
        let config = f.directory.appendingPathComponent("stdio/server.json")
        try ServerConfiguration.initialize(at: config, root: f.root.path)
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("link-server")
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["--stdio", "--config", config.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        func exchange(_ request: RPCRequest) throws -> RPCResponse {
            try input.fileHandleForWriting.write(contentsOf: WireJSON.encode(request) + Data([10]))
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 3000) == 1 else { throw RPCError("test_timeout", "Interactive stdio blocked") }
            var data = Data(), byte: UInt8 = 0
            while Darwin.read(descriptor.fd, &byte, 1) == 1 {
                if byte == 10 { break }; data.append(byte)
            }
            return try WireJSON.decode(RPCResponse.self, from: data)
        }
        let info = try exchange(RPCRequest(method: "server.info"))
        XCTAssertNil(info.error)
        let write = try exchange(RPCRequest(method: "fs.write", bootID: info.bootID,
                                            params: ["path": .string("stdio-file"), "data": .string("b2s=")]))
        XCTAssertNil(write.error)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("stdio-file")), Data("ok".utf8))
    }
}
