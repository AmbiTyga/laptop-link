import Foundation
import LinkProtocol

final class TerminalOperations {
    let configuration: ServerConfiguration
    let paths: PathPolicy
    let opened: @Sendable (TerminalSession) -> Void
    var sessions: [String: TerminalSession] = [:]
    init(configuration: ServerConfiguration, paths: PathPolicy,
         opened: @escaping @Sendable (TerminalSession) -> Void) {
        self.configuration = configuration; self.paths = paths; self.opened = opened
    }

    func handle(_ method: String, _ p: [String: JSONValue]) throws -> JSONValue {
        guard configuration.allowCommands else { throw RPCError("disabled", "Command execution is disabled") }
        if method == "terminal.open" { return try open(p).poll() }
        if method == "terminal.list" { return .array(try sessions.values.map { try $0.poll(count: 1) }) }
        guard let session = sessions[try p.requiredString("session_id")] else {
            throw RPCError("unknown_terminal", "Terminal does not exist in this server run")
        }
        if method == "terminal.read" {
            let offset = try p.integer("offset", default: 0, range: 0...Int.max)
            let count = try p.integer("max_bytes", default: 16_384, range: 1...32_768)
            return try session.poll(offset: Int64(offset), count: count)
        }
        guard let epoch = p["control_epoch"]?.int, epoch > 0 else {
            throw RPCError("invalid_params", "control_epoch from terminal.read is required")
        }
        switch method {
        case "terminal.write":
            let text = try p.requiredString("data")
            guard let data = Data(base64Encoded: text), data.base64EncodedString() == text else {
                throw RPCError("invalid_params", "Expected canonical base64 data")
            }
            try session.write(data, epoch: epoch)
            return .object(["session_id": .string(session.id), "accepted_bytes": .int(Int64(data.count))])
        case "terminal.resize":
            try session.resize(cols: p.integer("cols", default: 80, range: 2...500),
                               rows: p.integer("rows", default: 24, range: 2...200), epoch: epoch)
        case "terminal.close": try session.close(epoch: epoch)
        default: throw RPCError("unknown_method", method)
        }
        return try session.poll(count: 1)
    }

    func open(_ p: [String: JSONValue], local: Bool = false) throws -> TerminalSession {
        guard configuration.allowCommands else { throw RPCError("disabled", "Command execution is disabled") }
        guard sessions.count < min(32, configuration.maximumJobsPerRun),
              sessions.values.filter(\.running).count < configuration.maximumConcurrentJobs else {
            throw RPCError("limit", "Terminal session limit reached")
        }
        let cwd = try paths.resolve(p["cwd"]?.string ?? ".")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RPCError("invalid_params", "cwd must be a directory")
        }
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
                   "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "LANG": "en_US.UTF-8",
                   "TMPDIR": NSTemporaryDirectory(), "TERM": "xterm-256color", "COLORTERM": "truecolor"]
        if let value = p["env"] {
            guard let object = value.object else { throw RPCError("invalid_params", "env must be an object") }
            for (key, value) in object {
                guard !key.isEmpty, !key.contains("="), !key.contains("\0"),
                      let text = value.string, !text.contains("\0") else {
                    throw RPCError("invalid_params", "Invalid environment entry")
                }
                env[key] = text
            }
        }
        let session = try TerminalSession(cwd: cwd.path, environment: env,
            cols: p.integer("cols", default: 100, range: 2...500),
            rows: p.integer("rows", default: 30, range: 2...200),
            cap: configuration.outputBytesPerStream, local: local)
        sessions[session.id] = session; opened(session)
        return session
    }

    func shutdown() { sessions.values.forEach { $0.shutdown() } }
}
