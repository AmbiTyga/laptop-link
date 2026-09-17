import Foundation
import Darwin
import ProcessSupport
import LinkProtocol

extension TerminalSession {
    func setup() {
        let descriptor = fd
        let read = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        read.setEventHandler { [weak self] in self?.drain() }
        read.setCancelHandler { Darwin.close(descriptor) }
        reader = read; read.resume()
        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        process.setEventHandler { [weak self] in self?.didExit() }
        exitSource = process; process.resume()
    }

    func drain() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        for _ in 0..<64 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { output.append(Data(buffer.prefix(count))); continue }
            if count < 0, errno == EINTR { continue }
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                fd = -1; pending.removeAll(); reader?.cancel()
                if count < 0 && errno != EIO { ioError = String(cString: strerror(errno)) }
            }
            return
        }
    }

    func enqueue(_ data: Data) throws {
        guard state == "running", fd >= 0 else { throw RPCError("terminal_closed", "Terminal session has ended") }
        guard !data.isEmpty, data.count <= 65_536, pending.count + data.count <= 65_536 else {
            throw RPCError("limit", "Terminal input queue limit is 65536 bytes")
        }
        pending.append(data); pump()
        if let ioError { throw RPCError("terminal_io", ioError) }
    }

    func pump() {
        guard fd >= 0 else { return }
        while !pending.isEmpty {
            let count = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count > 0 { pending.removeFirst(count); continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if !pumpScheduled {
                    pumpScheduled = true
                    queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                        guard let self else { return }
                        self.pumpScheduled = false; self.pump()
                    }
                }
                return
            }
            ioError = String(cString: strerror(errno)); pending.removeAll(); break
        }
    }

    func didExit() {
        guard state == "running" else { return }
        // Kill other job-control groups before waitpid releases the leader's PID.
        link_terminal_kill_session(pid, SIGKILL)
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
        drain()
        reader?.cancel(); exitSource?.cancel()
        reader = nil; exitSource = nil; pending.removeAll()
        fd = -1
        if result == pid {
            let code = link_exit_code(status), sig = link_exit_signal(status)
            exitCode = code >= 0 ? code : nil; signal = sig > 0 ? sig : nil
        }
        state = "exited"; epoch += 1
    }
}
