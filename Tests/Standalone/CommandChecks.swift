import Foundation
import Darwin
import LinkProtocol

enum CommandChecks {
    static func execution() throws {
        let f = try RemoteFixture()
        let id = try f.result("exec.start", ["executable": .string("/bin/sh"),
            "args": .array([.string("-c"), .string("printf '%s' \"$MESSAGE\"; printf problem >&2; pwd > location; exit 7")]),
            "env": .object(["MESSAGE": .string("hello 🛠")])]).requiredString("job_id")
        let end = try f.wait(id)
        try require(end["exit_code"] == .int(7), "Wrong exit code")
        try require(try stream(end, "stdout") == Data("hello 🛠".utf8), "Environment/stdout mismatch")
        try require(try stream(end, "stderr") == Data("problem".utf8), "Stderr mismatch")
        let reported = try String(contentsOf: f.root.appendingPathComponent("location"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let a = try FileManager.default.attributesOfItem(atPath: reported)[.systemFileNumber] as? NSNumber
        let b = try FileManager.default.attributesOfItem(atPath: f.root.path)[.systemFileNumber] as? NSNumber
        try require(a == b && a != nil, "Wrong command working directory")
    }

    static func identities() throws {
        let f = try RemoteFixture(), uuid = UUID().uuidString
        let p: [String: JSONValue] = ["shell": .string("printf once >> count")]
        let first = try f.call("exec.start", p, id: uuid), second = try f.call("exec.start", p, id: uuid)
        try require(first.error == nil && first.result == second.result, "Duplicate start returned a different job")
        guard let id = first.result?.object?["job_id"]?.string else { throw CheckFailure("Missing job ID") }
        _ = try f.wait(id)
        try require(try Data(contentsOf: f.root.appendingPathComponent("count")) == Data("once".utf8), "Command ran twice")
        try require(try f.call("exec.start", ["shell": .string("false")], id: uuid).error?.code == "id_conflict", "Conflicting request ID allowed")
        let stale = RPCRequest(method: "exec.start", bootID: "previous-run", params: ["shell": .string("touch should-not-exist")])
        try require(try f.send(stale).error?.code == "server_changed", "Old boot ID accepted")
        try require(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("should-not-exist").path), "Stale request executed")
    }

    static func outputLimits() throws {
        let f = try RemoteFixture(outputCap: 1024)
        let id = try f.start("/usr/bin/yes output | /usr/bin/head -c 200000; /usr/bin/yes error | /usr/bin/head -c 200000 >&2")
        let end = try f.wait(id)
        try require(end["exit_code"] == .int(0), "Output-heavy command failed")
        for name in ["stdout", "stderr"] {
            try require(try stream(end, name).count == 1024, "Output cap failed for \(name)")
            try require(end[name]?.object?["discarded_bytes"] == .int(198_976), "Incorrect truncation count")
        }
    }

    static func outputCursors() throws {
        let f = try RemoteFixture(), id = try f.start("/usr/bin/yes abc | /usr/bin/head -c 70000")
        _ = try f.wait(id)
        var collected = Data(), offset: Int64 = 0
        while offset < 70_000 {
            let response = try f.result("exec.poll", ["job_id": .string(id), "stdout_offset": .int(offset), "max_bytes": .int(5000)])
            let chunk = try stream(response, "stdout")
            try require(!chunk.isEmpty, "Output cursor made no progress")
            collected.append(chunk)
            guard let next = response["stdout"]?.object?["next_offset"]?.int else { throw CheckFailure("Missing cursor") }
            offset = next
        }
        try require(collected.count == 70_000 && collected.prefix(8) == Data("abc\nabc\n".utf8), "Output cursor data mismatch")
    }

    static func timeout() throws {
        let f = try RemoteFixture()
        let id = try f.start("trap '' TERM; /bin/sleep 60 & child=$!; echo $child; while :; do /bin/sleep 1; done", timeout: 1)
        let end = try f.wait(id, seconds: 8)
        try require(end["state"] == .string("timed_out") && end["signal"] == .int(Int64(SIGKILL)), "Timeout failed to escalate")
        let output = String(decoding: try stream(end, "stdout"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(output) else { throw CheckFailure("Missing child PID") }
        for _ in 0..<100 where kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 0.02) }
        try require(kill(pid, 0) == -1, "Child survived timeout")
    }

    static func cancellation() throws {
        let f = try RemoteFixture(), id = try f.start("sleep 60", timeout: 60)
        try f.result("exec.cancel", ["job_id": .string(id)])
        try require(try f.wait(id)["state"] == .string("cancelled"), "Cancellation failed")
        try require(try f.call("exec.start", ["executable": .string("/no/such/file")]).error?.code == "spawn", "Bad executable accepted")
        try require(try f.call("exec.start", ["shell": .string("true"), "timeout_seconds": .int(0)]).error?.code == "invalid_params", "Zero timeout accepted")
        let disabled = try RemoteFixture(commands: false)
        try require(try disabled.call("exec.start", ["shell": .string("true")]).error?.code == "disabled", "Disabled commands ran")
        let short = try RemoteFixture(maximumTimeout: 1)
        let shortID = try short.result("exec.start", ["shell": .string("sleep 60")]).requiredString("job_id")
        try require(try short.wait(shortID)["state"] == .string("timed_out"), "Default timeout exceeded configured maximum")
    }
}
