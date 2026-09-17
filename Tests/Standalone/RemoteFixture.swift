import Foundation
import Darwin
import LinkProtocol
import LinkServerKit

/// Drives the actual server executable through pipes. No XCTest or SwiftPM runtime is used.
final class RemoteFixture {
    let directory: URL, root: URL
    private let process = Process(), input = Pipe(), output = Pipe()
    private var buffered = Data()
    private(set) var boot = ""

    init(commands: Bool = true, outputCap: Int = 4_194_304, maximumTimeout: Int = 3600) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ble-direct-check-\(UUID().uuidString)")
        root = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let configURL = directory.appendingPathComponent("config/server.json")
            try ServerConfiguration.initialize(at: configURL, root: root.path)
            var config = try ServerConfiguration.load(configURL)
            config.allowCommands = commands; config.outputBytesPerStream = outputCap
            config.maximumTimeoutSeconds = maximumTimeout
            try WireJSON.encode(config).write(to: configURL)
            let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("link-server")
            process.executableURL = ProcessInfo.processInfo.environment["LINK_TEST_SERVER"].map { URL(fileURLWithPath: $0) } ?? sibling
            process.arguments = ["--stdio", "--config", configURL.path]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
            try process.run()
            boot = try send(RPCRequest(method: "server.info")).bootID
            try require(!boot.isEmpty, "Server did not report a boot ID")
        } catch { stop(); try? FileManager.default.removeItem(at: directory); throw error }
    }

    deinit { stop(); try? FileManager.default.removeItem(at: directory) }

    func send(_ request: RPCRequest) throws -> RPCResponse {
        try input.fileHandleForWriting.write(contentsOf: WireJSON.encode(request) + Data([10]))
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while true {
            if let end = buffered.firstIndex(of: 10) {
                let line = Data(buffered[..<end]); buffered.removeSubrange(...end)
                let response = try WireJSON.decode(RPCResponse.self, from: line)
                try require(response.id == request.id, "Response ID does not match request")
                return response
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CheckFailure("Server did not reply to \(request.method) within five seconds") }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(remaining * 1000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw CheckFailure("Timed out waiting for \(request.method)") }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let size = Darwin.read(descriptor.fd, &chunk, chunk.count)
            guard size > 0 else { throw CheckFailure("Server exited before replying to \(request.method)") }
            buffered.append(contentsOf: chunk.prefix(size))
            try require(buffered.count <= 262_144, "Server response exceeded the test buffer limit")
        }
    }

    func call(_ method: String, _ params: [String: JSONValue] = [:], id: String = UUID().uuidString) throws -> RPCResponse {
        try send(RPCRequest(id: id, method: method, bootID: boot, params: params))
    }

    @discardableResult
    func result(_ method: String, _ params: [String: JSONValue] = [:]) throws -> [String: JSONValue] {
        let response = try call(method, params)
        if let error = response.error { throw error }
        guard let object = response.result?.object else { throw CheckFailure("Expected object result for \(method)") }
        return object
    }

    func start(_ shell: String, timeout: Int = 10) throws -> String {
        try result("exec.start", ["shell": .string(shell), "timeout_seconds": .int(Int64(timeout))]).requiredString("job_id")
    }

    func wait(_ id: String, seconds: Double = 10) throws -> [String: JSONValue] {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            let response = try result("exec.poll", ["job_id": .string(id), "max_bytes": .int(32_768)])
            if response["state"]?.string != "running" { return response }
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw CheckFailure("Job \(id) did not finish")
    }

    private func stop() {
        try? input.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        if process.processIdentifier > 0 { process.waitUntilExit() }
    }
}

func stream(_ result: [String: JSONValue], _ name: String) throws -> Data {
    guard let encoded = result[name]?.object?["data"]?.string, let data = Data(base64Encoded: encoded) else {
        throw CheckFailure("Missing/invalid base64 output in \(name)")
    }
    return data
}
