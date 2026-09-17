# Local and live BLE validation — 2026-09-17

Environment: Apple Silicon, macOS 26.3.1, Swift 6.3.3 (`swift-6.3.3-RELEASE`). Both build paths use Swift 6 language mode with no build-time package downloads; the Protobuf migration vendors SwiftProtobuf 1.38.1. The remote Mac reports Apple's Swift 6.3.3 compiler, but its `swift-package` crashes while loading BuildServerProtocol; the new default path bypasses that executable.

Current Protobuf migration checks:

- The public package also builds through SwiftPM with a fresh cache and passes all **17 XCTest tests** after adding the vendored runtime.

- **17/17 standalone checks passed**: the original 12 plus lossless binary/integer values, malformed-message limits and presence, both authenticated wire formats with domain separation, encrypted/framed size measurement, and binary file/command routing with cross-format retry deduplication.
- A 65536-byte upload chunk measured **116861 bytes with JSON and 65747 with Protobuf**, including AES-GCM tag, envelope, and four-byte frame length: **43.7% fewer bytes**.
- Large file bytes, stdout/stderr bytes, exact signed 64-bit values, empty objects/arrays, null, boolean false, Unicode, and unknown fields round-trip correctly. Explicit sequence zero is distinguished from a missing sequence.
- Both wire formats reject replay/tampering. A v1/v2 handshake mismatch fails authentication. Request UUID spelling and canonical request fingerprints survive conversion.

Earlier JSON baseline results (before the Protobuf migration):

Completed:

- `./scripts/check.sh`: **12 standalone checks passed**, zero failures. These require neither SwiftPM nor XCTest, and exercise the built server through its interactive stdio endpoint.
- Repeated the standalone build/checks with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`, using its macOS 26.2 SDK and clang with the installed Swift.org 6.3.3 compiler. Placed failing stubs for `swift`, `swift-package`, `xcodebuild`, and `xctest` first on PATH: build and all 12 checks still passed.
- `./scripts/check.sh --swiftpm`: the original **17 XCTest tests passed**, zero failures; this optional path remains available on working SwiftPM installations.
- Authentication: mutual key proof, wrong-key rejection, tamper rejection, directional keys, replay rejection.
- Framing: every split point, multiple frames, oversized-frame rejection, encrypted request through 20-byte simulated chunks into the real command router.
- Filesystem: file round trip, ranged read, stale hash rejection, patch, duplicate append, root traversal rejection, symlink escape rejection, safe symlink move/delete, search, copy/move/delete.
- Upload: 150000-byte binary transfer in multiple chunks, out-of-order rejection, final SHA-256 verification, failed checksum preserves existing destination.
- Commands: explicit executable/arguments, environment and working directory, stdout/stderr, nonzero exit, output larger than pipe buffers, output caps and discarded-byte counts, output cursors after exit, cancellation, duplicate start deduplication, timeout escalation and child-process-group cleanup, disabled commands and invalid executable/timeout handling.
- Interactive stdio: the built executable replies before stdin reaches EOF; subsequent write RPC works in the same process.
- `./scripts/package-apps.sh`: optimized native arm64 build and app bundles produced directly using swiftc/clang and the Command Line Tools SDK, with the same failing package/test-tool stubs on PATH.
- App property lists and local ad-hoc code signatures verified.
- Packaged release server: **12/12 standalone checks passed** with the runner pointed at `dist/LaptopLinkServer.app/Contents/MacOS/link-server` through `LINK_TEST_SERVER`.
- Remote Mac: **12/12 standalone checks passed** using Apple's Swift 6.3.3 (`swiftlang-6.3.3.1.3`) and the explicitly selected macOS 26.5 Command Line Tools SDK. Confirmed from its shared test log. The default macOS 27.0 SDK required Swift 6.4 and was incompatible with that compiler.

Live tests between two physical Macs also passed:

- BLE discovery, GATT connection/subscription, shared-key authentication, and encrypted `server.info`.
- 1024-byte binary write/read with exact byte and SHA-256 verification.
- Remote shell command returned exact stdout `hello-over-BLE`, stderr `stderr-over-BLE`, and exit code 7.
- Repeating the same command request UUID and bootID across fresh connections returned the same job ID.
- A command with a one-second execution timeout reached `timed_out` and retained its earlier stdout when polled through a new BLE connection.
- 70000-byte binary upload using a 65536-byte chunk plus a remainder, commit, ranged download, and SHA-256 verification. Downloaded bytes matched exactly. The first upload chunk took approximately 18 seconds including discovery/authentication overhead; this is one observation, not a throughput guarantee.
- Temporary files from the diagnostic tests were deleted after verification. Diagnostic clients disconnect after each RPC; the companion MCP bridge maintains a persistent authenticated session.
- The companion Laptop Link MCP server initialized through the official MCP client, listed 26 tools, and ran remote OS/hardware inspection commands over BLE. stdout was captured, stderr was empty, and exit status was 0.
- A requested remote directory and greeting file were created through MCP. A chunked upload, read-back, and SHA-256 check confirmed the bytes. The requested file was retained.

Not yet verified:

- Physical Protobuf sessions and MCP automatic upgrade between two Macs; the live results above apply to the earlier JSON baseline. The unchanged JSON client also timed out during the migration follow-up.

- Forced link loss during a request, sleep/wake recovery, denied Bluetooth permissions, long-duration reliability, and sustained throughput.
- Intel or universal build, and execution on older macOS releases.
- Automatic loading in each supported agent UI; the stdio MCP protocol is verified independently with the official SDK client.

The earlier JSON baseline verified the two-Mac connection, file transfer, command execution, and companion MCP stdio path. The remaining acceptance cases in SETUP.md require additional device testing. No enrollment key is included in this report or the source archive.
