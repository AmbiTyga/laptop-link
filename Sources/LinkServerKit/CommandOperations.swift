import Foundation
import LinkProtocol

final class CommandOperations {
    private let configuration: ServerConfiguration
    private let paths: PathPolicy
    private let directory: URL
    private var jobs: [String: CommandJob] = [:]
    init(configuration: ServerConfiguration, paths: PathPolicy, directory: URL) throws {
        self.configuration = configuration; self.paths = paths; self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func handle(_ method: String, _ p: [String: JSONValue]) throws -> JSONValue {
        guard configuration.allowCommands else { throw RPCError("disabled", "Command execution is disabled") }
        if method == "exec.start" { return try start(p) }
        if method == "exec.list" {
            return .array(try jobs.values.map { try $0.poll(["max_bytes": .int(1)]) })
        }
        let id = try p.requiredString("job_id")
        guard let job = jobs[id] else { throw RPCError("unknown_job", "Job does not exist in this server run") }
        switch method {
        case "exec.poll": return try job.poll(p)
        case "exec.cancel": job.cancel(); return try job.poll(p)
        default: throw RPCError("unknown_method", method)
        }
    }

    private func start(_ p: [String: JSONValue]) throws -> JSONValue {
        guard jobs.count < configuration.maximumJobsPerRun,
              jobs.values.filter(\.running).count < configuration.maximumConcurrentJobs else {
            throw RPCError("limit", "Job count limit reached")
        }
        let executable: String, arguments: [String]
        if let shell = p["shell"]?.string {
            guard p["executable"] == nil, p["args"] == nil else {
                throw RPCError("invalid_params", "Use shell or executable/args")
            }
            executable = "/bin/zsh"; arguments = ["-c", shell]
        } else {
            executable = try p.requiredString("executable")
            guard executable.hasPrefix("/") else { throw RPCError("invalid_params", "Executable must be an absolute path") }
            let raw = p["args"]?.array ?? []
            arguments = try raw.map {
                guard let value = $0.string else { throw RPCError("invalid_params", "args must contain strings") }
                return value
            }
        }
        let cwd = try paths.resolve(p["cwd"]?.string ?? ".")
        let timeout = try p.integer("timeout_seconds", default: min(60, configuration.maximumTimeoutSeconds),
                                    range: 1...configuration.maximumTimeoutSeconds)
        // Do not pass the server's full environment (which can contain unrelated credentials).
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
                           "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                           "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
        if let supplied = p["env"] {
            guard let values = supplied.object else { throw RPCError("invalid_params", "env must be an object") }
            for (key, value) in values {
                guard !key.isEmpty, !key.contains("="), !key.contains("\0"), let text = value.string, !text.contains("\0") else {
                    throw RPCError("invalid_params", "Invalid environment entry")
                }
                environment[key] = text
            }
        }
        guard !executable.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }),
              arguments.reduce(0, { $0 + $1.utf8.count }) < 65_536 else {
            throw RPCError("invalid_params", "Invalid or oversized arguments")
        }
        let location = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let job = try CommandJob(executable: executable, arguments: arguments, environment: environment,
                                     cwd: cwd.path, timeout: timeout, directory: location,
                                     outputCap: configuration.outputBytesPerStream)
            jobs[job.id] = job
            return .object(["job_id": .string(job.id)])
        } catch { try? FileManager.default.removeItem(at: location); throw error }
    }

    func shutdown() { jobs.values.forEach { $0.shutdown() } }
}
