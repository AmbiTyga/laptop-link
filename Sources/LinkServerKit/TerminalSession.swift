import Foundation
import Darwin
import ProcessSupport
import LinkProtocol

/// One real PTY and persistent shell. All state and input ownership share one queue.
public final class TerminalSession: @unchecked Sendable {
    public let id = UUID().uuidString
    let queue = DispatchQueue(label: "ble.terminal")
    var pid: pid_t = 0, fd: Int32 = -1
    var reader: DispatchSourceRead?, exitSource: DispatchSourceProcess?
    var pumpScheduled = false
    var pending = Data()
    let output: TerminalOutput
    var state = "running", owner: String
    var epoch: Int64 = 1
    var cols: Int, rows: Int
    var exitCode: Int32?, signal: Int32?
    var ioError: String?
    let cwd: String

    init(cwd: String, environment: [String: String], cols: Int, rows: Int, cap: Int, local: Bool) throws {
        self.cwd = cwd; self.cols = cols; self.rows = rows
        owner = local ? "local" : "agent"; output = TerminalOutput(cap: cap)
        let argv = [strdup("/bin/zsh"), strdup("-i"), nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        let code = argv.withUnsafeBufferPointer { av in
            envp.withUnsafeBufferPointer { ev in
                link_terminal_spawn("/bin/zsh", av.baseAddress, ev.baseAddress, cwd, Int32(cols), Int32(rows), &pid, &fd)
            }
        }
        guard code == 0 else { throw RPCError("spawn", String(cString: strerror(code))) }
        queue.sync { setup() }
    }

    public var running: Bool { queue.sync { state == "running" } }

    public func poll(offset: Int64 = 0, count: Int = 16_384) throws -> JSONValue {
        guard (1...32_768).contains(count) else { throw RPCError("invalid_params", "Invalid terminal read size") }
        return try queue.sync {
            .object(["session_id": .string(id), "state": .string(state), "owner": .string(owner),
                     "control_epoch": .int(epoch), "initial_cwd": .string(cwd), "pid": .int(Int64(pid)),
                     "cols": .int(Int64(cols)), "rows": .int(Int64(rows)),
                     "exit_code": exitCode.map { .int(Int64($0)) } ?? .null,
                     "signal": signal.map { .int(Int64($0)) } ?? .null,
                     "io_error": ioError.map(JSONValue.string) ?? .null,
                     "pending_input_bytes": .int(Int64(pending.count)),
                     "output": try output.read(offset: offset, count: count)])
        }
    }

    func authorize(_ expected: Int64) throws {
        guard state == "running" else { throw RPCError("terminal_closed", "Terminal session has ended") }
        guard owner == "agent" else { throw RPCError("local_control", "The local user controls this terminal") }
        guard epoch == expected else { throw RPCError("stale_control", "Control changed; read output and use the current epoch") }
    }

    func write(_ data: Data, epoch: Int64) throws {
        try queue.sync { try authorize(epoch); try enqueue(data) }
    }

    func resize(cols: Int, rows: Int, epoch: Int64) throws {
        try queue.sync { try authorize(epoch); try setSize(cols: cols, rows: rows) }
    }

    func close(epoch: Int64) throws {
        try queue.sync { try authorize(epoch); terminate() }
    }

    /// Only local UI code can change ownership. Remote APIs cannot reclaim it.
    public func setLocalControl(_ local: Bool) {
        queue.sync {
            guard state == "running", owner != (local ? "local" : "agent") else { return }
            owner = local ? "local" : "agent"; epoch += 1
            pending.removeAll()
        }
    }

    public func localInput(_ data: Data) throws {
        try queue.sync {
            guard owner == "local" else { throw RPCError("agent_control", "Click Take Control before typing") }
            try enqueue(data)
        }
    }

    /// Terminal protocol replies (e.g. cursor position) are not user keystrokes.
    public func terminalReply(_ data: Data) throws { try queue.sync { try enqueue(data) } }
    public func localResize(cols: Int, rows: Int) throws {
        try queue.sync { if state == "running" { try setSize(cols: cols, rows: rows) } }
    }
    public func localClose() { queue.sync { terminate() } }
    public func shutdown() { queue.sync { if state == "running" { terminate(); didExit() } } }

    func terminate() {
        guard state == "running" else { return }
        // Explicit close ends the entire interactive session, including background jobs.
        link_terminal_kill_session(pid, SIGKILL)
    }

    func setSize(cols: Int, rows: Int) throws {
        guard (2...500).contains(cols), (2...200).contains(rows) else {
            throw RPCError("invalid_params", "Terminal size must be 2–500 columns and 2–200 rows")
        }
        let code = link_terminal_resize(fd, Int32(cols), Int32(rows))
        guard code == 0 else { throw RPCError("terminal_io", String(cString: strerror(code))) }
        self.cols = cols; self.rows = rows
    }
}
