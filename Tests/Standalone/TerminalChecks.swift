import Foundation
import Darwin
import LinkProtocol
import LinkServerKit

private final class TerminalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TerminalSession?
    func put(_ value: TerminalSession) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func get() -> TerminalSession { lock.lock(); defer { lock.unlock() }; return value! }
}

private final class TerminalFixture {
    let root: URL
    let router: RequestRouter
    let box = TerminalBox()
    var session: TerminalSession { box.get() }
    init(cap: Int = 4_194_304, enabled: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ble-terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        var config = ServerConfiguration(root: root.path, stateDirectory: root.appendingPathComponent("state").path,
                                         keyFile: root.appendingPathComponent("key").path)
        config.outputBytesPerStream = cap; config.allowCommands = enabled
        let storage = box
        router = try RequestRouter(configuration: config, terminalOpened: { storage.put($0) })
    }
    deinit { router.shutdown(); try? FileManager.default.removeItem(at: root) }
    func request(_ method: String, _ params: [String: JSONValue] = [:], id: String = UUID().uuidString) -> RPCResponse {
        router.handle(RPCRequest(id: id, method: method, bootID: router.bootID, params: params))
    }
    func open() throws {
        let reply = request("terminal.open", ["env": .object(["HOME": .string(root.path), "ZDOTDIR": .string(root.path)])])
        try require(reply.error == nil, "Terminal open failed: \(String(describing: reply.error))")
    }
    func input(_ text: String, epoch: Int64 = 1, id: String = UUID().uuidString) throws -> RPCResponse {
        // Exercise terminal.write's binary conversion at the same boundary used by BLE.
        let p: [String: JSONValue] = ["session_id": .string(session.id), "control_epoch": .int(epoch),
                                     "data": .string(Data(text.utf8).base64EncodedString())]
        let request = RPCRequest(id: id, method: "terminal.write", bootID: router.bootID, params: p)
        return router.handle(try WireFormat.protobuf.decodeRequest(WireFormat.protobuf.encodeRequest(request)))
    }
    func wait(_ marker: String? = nil, exited: Bool = false) throws -> [String: JSONValue] {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            let result = try session.poll(count: 32_768).object!
            let bytes = Data(base64Encoded: result["output"]!.object!["data"]!.string!)!
            if (!exited || result["state"] == .string("exited")), marker == nil || String(decoding: bytes, as: UTF8.self).contains(marker!) {
                return result
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw CheckFailure("Terminal output/state did not arrive: \(marker ?? "exit")")
    }
}

enum TerminalChecks {
    static func persistentShell() throws {
        let f = try TerminalFixture(); try f.open()
        try require(try f.input("cd sub; export BLE_PERSIST=yes; printf 'READY_%s\\n' ONE\n").error == nil, "Input rejected")
        _ = try f.wait("READY_ONE")
        _ = try f.input("printf 'PERSIST:%s:%s\\n' \"${PWD:t}\" \"$BLE_PERSIST\"\n")
        _ = try f.wait("PERSIST:sub:yes")
        let id = UUID().uuidString
        let command = "printf x >> count; printf 'DONE_%s\\n' ONCE\n"
        let reply = try f.input(command, id: id)
        try require(try f.input(command, id: id).result == reply.result, "Write retry changed response")
        _ = try f.wait("DONE_ONCE")
        try require(try String(contentsOf: f.root.appendingPathComponent("sub/count"), encoding: .utf8) == "x", "Duplicate terminal input executed")
        let resize = f.request("terminal.resize", ["session_id": .string(f.session.id), "control_epoch": .int(1), "cols": .int(93), "rows": .int(31)])
        try require(resize.error == nil, "Resize failed")
        _ = try f.input("stty size; printf 'SIZE_%s\\n' DONE\n")
        _ = try f.wait("31 93")
        _ = try f.input("exit 7\n")
        try require(try f.wait(exited: true)["exit_code"] == .int(7), "Shell exit status lost")
    }

    static func ownership() throws {
        let f = try TerminalFixture(); try f.open()
        f.session.setLocalControl(true)
        try require(try f.input("printf forbidden\n").error?.code == "local_control", "Agent input bypassed takeover")
        for method in ["terminal.resize", "terminal.close"] {
            let reply = f.request(method, ["session_id": .string(f.session.id), "control_epoch": .int(1)])
            try require(reply.error?.code == "local_control", "Agent bypassed local ownership")
        }
        try f.session.localInput(Data("export BLE_LOCAL=yes; printf 'LOCAL_%s\\n' READY\n".utf8))
        _ = try f.wait("LOCAL_READY")
        f.session.setLocalControl(false)
        try require(try f.input("printf stale\n").error?.code == "stale_control", "Old epoch accepted after handoff")
        try rejects { try f.session.localInput(Data("blocked\n".utf8)) }
        _ = try f.input("printf 'BACK:%s\\n' \"$BLE_LOCAL\"\n", epoch: 3)
        _ = try f.wait("BACK:yes")
        _ = try f.input("sleep 30\n", epoch: 3)
        Thread.sleep(forTimeInterval: 0.15)
        _ = try f.input("\u{3}", epoch: 3)
        _ = try f.input("printf 'INTERRUPT_%s\\n' OK\n", epoch: 3)
        _ = try f.wait("INTERRUPT_OK")
        try require(f.session.running, "Ctrl+C terminated the shell")
    }

    static func limitsAndCleanup() throws {
        let disabled = try TerminalFixture(enabled: false)
        try require(disabled.request("terminal.open").error?.code == "disabled", "Disabled commands permit terminals")
        let f = try TerminalFixture(cap: 1024); try f.open()
        _ = try f.input("printf '%02000d' 0; printf 'TAIL_%s\\n' OK\n")
        let result = try f.wait("TAIL_OK")
        try require(result["output"]?.object?["truncated"] == .bool(true), "Missing history truncation")
        try require(result["output"]!.object!["first_offset"]!.int! > 0, "Rolling cursor did not advance")
        _ = try f.input("sleep 30 & echo $! > child.pid; printf 'CHILD_%s\\n' READY\n")
        _ = try f.wait("CHILD_READY")
        let child = Int32(try String(contentsOf: f.root.appendingPathComponent("child.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        f.router.shutdown()
        try require(!f.session.running, "Shutdown left terminal running")
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while kill(child, 0) == 0, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        try require(kill(child, 0) != 0 && errno == ESRCH, "Terminal background job survived shutdown")
    }
}
