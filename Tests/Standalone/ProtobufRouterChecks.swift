import Foundation
import LinkProtocol
import LinkServerKit

/// Exercise the exact binary request/response boundary used by the BLE peripheral.
enum ProtobufRouterChecks {
    private final class Reply: @unchecked Sendable {
        // One writer and a waiting reader, synchronized by the semaphore.
        var data = Data()
        let ready = DispatchSemaphore(value: 0)
    }

    static func routing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ble-protobuf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ServerConfiguration(root: root.path, stateDirectory: root.appendingPathComponent("state").path,
                                         keyFile: root.appendingPathComponent("key").path)
        let router = try RequestRouter(configuration: config)
        defer { router.shutdown() }
        func call(_ request: RPCRequest, format: WireFormat = .protobuf) throws -> RPCResponse {
            let reply = Reply()
            router.handle(try format.encodeRequest(request), format: format) { data in
                reply.data = data; reply.ready.signal()
            }
            guard reply.ready.wait(timeout: .now() + 5) == .success else { throw CheckFailure("Router did not respond") }
            return try format.decodeResponse(reply.data)
        }
        let raw = Data((0..<65_536).map { UInt8($0 % 256) })
        let write = RPCRequest(method: "fs.write", bootID: router.bootID,
                               params: ["path": .string("binary"), "data": .string(raw.base64EncodedString())])
        try require(try call(write).error == nil, "Protobuf write failed")
        let append = RPCRequest(id: UUID().uuidString.lowercased(), method: "fs.append", bootID: router.bootID,
                                params: ["path": .string("binary"), "data": .string("AQ==")])
        let first = try call(append)
        try require(try call(append, format: .json).result == first.result, "Cross-format retry changed fingerprint")
        try require(try Data(contentsOf: root.appendingPathComponent("binary")) == raw + Data([1]), "Append repeated")
        let read = try call(RPCRequest(method: "fs.read", bootID: router.bootID,
                                      params: ["path": .string("binary"), "length": .int(65_536)]))
        try require(read.result?.object?["data"] == .string(raw.base64EncodedString()), "Protobuf read corrupted data")
        let start = RPCRequest(method: "exec.start", bootID: router.bootID,
                               params: ["shell": .string("printf output; printf error >&2; exit 7")])
        let started = try call(start)
        try require(try call(start).result == started.result, "Command was submitted twice")
        guard let job = started.result?.object?["job_id"] else { throw CheckFailure("No job ID") }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let poll = try call(RPCRequest(method: "exec.poll", bootID: router.bootID, params: ["job_id": job]))
            if let result = poll.result?.object, result["state"] != .string("running") {
                try require(result["exit_code"] == .int(7), "Wrong command exit")
                try require(try stream(result, "stdout") == Data("output".utf8), "Wrong stdout")
                try require(try stream(result, "stderr") == Data("error".utf8), "Wrong stderr")
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw CheckFailure("Command did not finish")
    }
}
