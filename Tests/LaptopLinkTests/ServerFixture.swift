import Foundation
import XCTest
import LinkProtocol
import LinkServerKit

final class ServerFixture {
    let directory: URL
    let root: URL
    let router: RequestRouter
    init(commands: Bool = true, cap: Int = 4_194_304) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ble-test-\(UUID().uuidString)")
        root = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = ServerConfiguration(root: root.path, stateDirectory: directory.appendingPathComponent("state").path,
                                         keyFile: directory.appendingPathComponent("key").path)
        config.allowCommands = commands; config.outputBytesPerStream = cap
        router = try RequestRouter(configuration: config)
    }
    deinit { router.shutdown(); try? FileManager.default.removeItem(at: directory) }

    func call(_ method: String, _ params: [String: JSONValue] = [:], id: String = UUID().uuidString) -> RPCResponse {
        router.handle(RPCRequest(id: id, method: method, bootID: router.bootID, params: params))
    }

    func result(_ method: String, _ params: [String: JSONValue] = [:]) throws -> [String: JSONValue] {
        let response = call(method, params)
        if let error = response.error { throw error }
        return try XCTUnwrap(response.result?.object)
    }

    func start(_ shell: String, timeout: Int = 10) throws -> String {
        try XCTUnwrap(result("exec.start", ["shell": .string(shell), "timeout_seconds": .int(Int64(timeout))])["job_id"]?.string)
    }

    func wait(_ id: String, seconds: Double = 10) throws -> [String: JSONValue] {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            let result = try self.result("exec.poll", ["job_id": .string(id), "max_bytes": .int(32_768)])
            if result["state"]?.string != "running" { return result }
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw RPCError("test_timeout", "Job did not finish")
    }
}

func decoded(_ result: [String: JSONValue], _ stream: String) throws -> Data {
    let text = try XCTUnwrap(result[stream]?.object?["data"]?.string)
    return try XCTUnwrap(Data(base64Encoded: text))
}
