import XCTest
import Foundation
import Darwin
import LinkProtocol

final class CommandTests: XCTestCase {
    func testExitStreamsArgumentsEnvironmentAndCwd() throws {
        let f = try ServerFixture()
        let result = try f.result("exec.start", ["executable": .string("/bin/sh"),
            "args": .array([.string("-c"), .string("printf '%s' \"$MESSAGE\"; printf 'problem' >&2; pwd > location; exit 7")]),
            "env": .object(["MESSAGE": .string("hello 🛠")])])
        let id = try XCTUnwrap(result["job_id"]?.string), end = try f.wait(id)
        XCTAssertEqual(end["exit_code"], .int(7))
        XCTAssertEqual(try decoded(end, "stdout"), Data("hello 🛠".utf8))
        XCTAssertEqual(try decoded(end, "stderr"), Data("problem".utf8))
        let reported = try String(contentsOf: f.root.appendingPathComponent("location"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: reported)[.systemFileNumber] as? NSNumber,
                       try FileManager.default.attributesOfItem(atPath: f.root.path)[.systemFileNumber] as? NSNumber)
    }

    func testNoPipeDeadlockAndBoundedOutput() throws {
        let f = try ServerFixture(cap: 1024)
        let id = try f.start("/usr/bin/yes output | /usr/bin/head -c 200000; /usr/bin/yes error | /usr/bin/head -c 200000 >&2")
        let result = try f.wait(id)
        XCTAssertEqual(result["exit_code"], .int(0))
        for stream in ["stdout", "stderr"] {
            XCTAssertEqual(try decoded(result, stream).count, 1024)
            XCTAssertEqual(result[stream]?.object?["discarded_bytes"], .int(198_976))
        }
    }

    func testTimeoutKillsProcessGroupAndRetainsOutput() throws {
        let f = try ServerFixture()
        let id = try f.start("trap '' TERM; /bin/sleep 60 & child=$!; echo $child; while :; do /bin/sleep 1; done", timeout: 1)
        let result = try f.wait(id, seconds: 8)
        XCTAssertEqual(result["state"], .string("timed_out"))
        XCTAssertEqual(result["signal"], .int(Int64(SIGKILL)))
        let pid = try XCTUnwrap(Int32(String(decoding: decoded(result, "stdout"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        // Launchd can briefly retain a reparented zombie; wait for its reap.
        for _ in 0..<100 where kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testCancellationAndRepeatedStart() throws {
        let f = try ServerFixture(), requestID = UUID().uuidString
        let p: [String: JSONValue] = ["shell": .string("echo started; sleep 60"), "timeout_seconds": .int(60)]
        let first = f.call("exec.start", p, id: requestID)
        let repeated = f.call("exec.start", p, id: requestID)
        XCTAssertEqual(first.result, repeated.result)
        let id = try XCTUnwrap(first.result?.object?["job_id"]?.string)
        Thread.sleep(forTimeInterval: 0.05)
        _ = try f.result("exec.cancel", ["job_id": .string(id)])
        XCTAssertEqual(try f.wait(id)["state"], .string("cancelled"))
    }

    func testDisabledInvalidExecutableAndTimeoutBounds() throws {
        let f = try ServerFixture(commands: false)
        XCTAssertEqual(f.call("exec.start", ["shell": .string("true")]).error?.code, "disabled")
        let g = try ServerFixture()
        XCTAssertEqual(g.call("exec.start", ["executable": .string("/no/such/executable")]).error?.code, "spawn")
        XCTAssertEqual(g.call("exec.start", ["shell": .string("true"), "timeout_seconds": .int(0)]).error?.code, "invalid_params")
    }
}
