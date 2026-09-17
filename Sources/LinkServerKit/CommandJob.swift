import Foundation
import Dispatch
import Darwin
import ProcessSupport
import LinkProtocol

/// All mutable state is confined to queue; public access synchronizes onto that queue.
final class CommandJob: @unchecked Sendable {
    let id = UUID().uuidString
    private let queue = DispatchQueue(label: "ble.command-job")
    private var pid: pid_t = 0
    private var outputFD: Int32 = -1, errorFD: Int32 = -1
    private var outputSource: DispatchSourceRead?, errorSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?, timer: DispatchSourceTimer?
    private let output: OutputSpool, errors: OutputSpool
    private var state = "running"
    private var exitCode: Int32?, signal: Int32?
    private var terminationReason: String?
    private let started = Date()
    private var finished: Date?

    init(executable: String, arguments: [String], environment: [String: String], cwd: String,
         timeout: Int, directory: URL, outputCap: Int) throws {
        output = try OutputSpool(url: directory.appendingPathComponent("stdout"), cap: outputCap)
        errors = try OutputSpool(url: directory.appendingPathComponent("stderr"), cap: outputCap)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        let code = argv.withUnsafeBufferPointer { av in
            envp.withUnsafeBufferPointer { ev in
                link_spawn(executable, av.baseAddress, ev.baseAddress, cwd, &pid, &outputFD, &errorFD)
            }
        }
        guard code == 0 else { throw RPCError("spawn", String(cString: strerror(code))) }
        // Sources only begin running after every stored property has been initialized.
        queue.sync { setup(timeout: timeout) }
    }

    private func setup(timeout: Int) {
        outputSource = reader(fd: outputFD, spool: output)
        errorSource = reader(fd: errorFD, spool: errors)
        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        process.setEventHandler { [weak self] in self?.didExit() }
        exitSource = process
        process.resume()
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + .seconds(timeout))
        deadline.setEventHandler { [weak self] in self?.terminate(reason: "timed_out") }
        timer = deadline
        deadline.resume()
    }

    private func reader(fd: Int32, spool: OutputSpool) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            if self?.drain(fd, into: spool) == true { source?.cancel() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }

    @discardableResult
    private func drain(_ fd: Int32, into spool: OutputSpool) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Bound each callback so a noisy process cannot starve timeout/cancellation.
        for _ in 0..<64 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { spool.append(Data(buffer.prefix(count))); continue }
            if count < 0, errno == EINTR { continue }
            return count == 0 || (count < 0 && errno != EAGAIN)
        }
        return false
    }

    private func didExit() {
        guard state == "running" else { return }
        // Kill remaining group members before reaping the leader, while its PID cannot be reused.
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
        if outputSource?.isCancelled == false { drain(outputFD, into: output) }
        if errorSource?.isCancelled == false { drain(errorFD, into: errors) }
        outputSource?.cancel(); errorSource?.cancel(); exitSource?.cancel(); timer?.cancel()
        if result == pid {
            let code = link_exit_code(status), sig = link_exit_signal(status)
            exitCode = code >= 0 ? code : nil; signal = sig > 0 ? sig : nil
        }
        state = terminationReason ?? "exited"; finished = Date()
    }

    private func terminate(reason: String) {
        guard state == "running", terminationReason == nil else { return }
        terminationReason = reason
        kill(-pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            guard let self, self.state == "running" else { return }
            kill(-self.pid, SIGKILL)
        }
    }

    func cancel() { queue.sync { terminate(reason: "cancelled") } }
    var running: Bool { queue.sync { state == "running" } }

    func shutdown() {
        queue.sync {
            if state == "running" {
                terminationReason = "cancelled"; kill(-pid, SIGKILL); didExit()
            }
        }
    }

    func poll(_ p: [String: JSONValue]) throws -> JSONValue {
        let out = try p.integer("stdout_offset", default: 0, range: 0...Int.max)
        let err = try p.integer("stderr_offset", default: 0, range: 0...Int.max)
        let count = try p.integer("max_bytes", default: 16_384, range: 1...32_768)
        return try queue.sync {
            .object(["job_id": .string(id), "state": .string(state), "pid": .int(Int64(pid)),
                     "exit_code": exitCode.map { .int(Int64($0)) } ?? .null,
                     "signal": signal.map { .int(Int64($0)) } ?? .null,
                     "termination_requested": terminationReason.map(JSONValue.string) ?? .null,
                     "started": .double(started.timeIntervalSince1970),
                     "finished": finished.map { .double($0.timeIntervalSince1970) } ?? .null,
                     "stdout": try output.read(offset: out, count: count),
                     "stderr": try errors.read(offset: err, count: count)])
        }
    }
}
