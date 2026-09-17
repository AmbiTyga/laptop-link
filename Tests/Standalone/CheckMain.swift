import Foundation
import LinkProtocol

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(message) }
}

func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw CheckFailure("Operation unexpectedly succeeded")
}

@main
struct CheckMain {
    static func main() {
        let checks: [(String, () throws -> Void)] = [
            ("frame fragmentation and size limits", ProtocolChecks.frames),
            ("authentication, encryption, tamper and replay rejection", ProtocolChecks.authentication),
            ("file read/write, hash, patch and append deduplication", FileChecks.files),
            ("directory listing, search, copy, move and delete", FileChecks.directories),
            ("path containment and safe symlink deletion", FileChecks.paths),
            ("chunked upload and failed-checksum preservation", FileChecks.uploads),
            ("command arguments, environment, cwd and exit status", CommandChecks.execution),
            ("command deduplication and stale boot rejection", CommandChecks.identities),
            ("simultaneous stdout/stderr drainage and truncation", CommandChecks.outputLimits),
            ("output cursors after process exit", CommandChecks.outputCursors),
            ("timeout escalation and process-group cleanup", CommandChecks.timeout),
            ("cancellation and execution configuration", CommandChecks.cancellation)
        ]
        var failures = 0
        for (name, check) in checks {
            do { try check(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
            fflush(stdout)
        }
        print("\(checks.count - failures)/\(checks.count) standalone checks passed; \(failures) failed.")
        print("BLE radio behavior requires testing between two physical Macs.")
        exit(failures == 0 ? 0 : 1)
    }
}
