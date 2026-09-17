# Laptop Link

A Swift 6.3.3 toolkit for communicating between laptops over Bluetooth Low Energy. The current implementation connects two Macs: one runs a menu bar server, and the other uses a client to exchange files and run CLI commands. No internet, IP network, Python runtime, or downloaded Swift packages are required by the server.

This release includes the server and a diagnostic BLE client. File transfers, remote command output, and command timeouts have been verified between two physical Macs; see [validation results](docs/VALIDATION.md). For Claude, Codex, and other MCP clients, use the companion [Laptop Link MCP](https://github.com/AmbiTyga/laptop-link-mcp) project and its portable Agent Skill.

## Install on the remote laptop

Clone this repository on the Mac that will run the server:

```sh
git clone https://github.com/AmbiTyga/laptop-link.git
cd laptop-link
```

For offline setup, copy this entire source folder (excluding `.build` and `.git`), or copy and extract `dist/laptop-link-source.tar.gz` into an empty folder:

```sh
mkdir laptop-link
tar -xzf laptop-link-source.tar.gz -C laptop-link
cd laptop-link
swiftc --version
./scripts/check.sh
./scripts/package-apps.sh
open dist/LaptopLinkServer.app
```

Use the existing **Swift 6.3.3 compiler** with Command Line Tools (or Xcode) and its macOS SDK. The default scripts compile directly with `swiftc` and `clang`: **Swift Package Manager, XCTest, Swiftly, and a full Xcode installation are not required.** This supports a Mac where `swift --version` works but `swift package` crashes. No toolchain replacement is needed if the installed compiler and SDK work. See [remote Mac setup](docs/SETUP.md).

On first launch, choose an existing workspace folder and allow Bluetooth access. The app displays **BLE** in the menu bar. Open its menu to see advertising/connection status or the configuration folder. Both Macs must be awake and within BLE range.

The first launch generates a unique, random 32-byte enrollment key:

```text
~/Library/Application Support/LaptopLink/client.key
```

Transfer that file privately to the controlling Mac. Possession of this key authorizes remote filesystem access and command execution. **Do not include it in the source archive or paste its contents into a chat.** No credentials are shipped with the source code.

## Protobuf transport

Laptop-to-laptop messages now use **binary Protobuf** for both RPC bodies and encrypted envelopes. A 65536-byte upload chunk measured **65747 framed bytes**, versus **116861 with JSON**: **43.7% less application data**, including encryption and framing. This is a size measurement, not a promise of the same reduction in elapsed transfer time.

The server accepts both Protobuf v2 and legacy JSON v1. The diagnostic client defaults to Protobuf; pass `--wire json` for a server built before this migration. The companion MCP can automatically select Protobuf after authenticating and querying capabilities. Existing JSON CLI request files and MCP tools keep their format.

The SwiftProtobuf 1.38.1 runtime, its license/privacy manifest, and generated Swift messages are included in the repository. Normal builds require no `protoc`, code-generation step, package download, or working SwiftPM. The schema is in `Protocol/ble_wire.proto`; `scripts/generate-protobuf.sh` is only for maintainers changing it. See [the wire specification](docs/PROTOCOL.md).

## Capabilities

- Directory listings, metadata, ranged binary reads, literal searches, SHA-256 hashes.
- Atomic file replacement, append, hash-checked text patches, mkdir, file copy, move, delete.
- Chunked uploads up to 64 MiB by default, with offsets and SHA-256 validation before replacement.
- Commands with explicit executable/arguments or a shell string; working directory and environment overrides.
- Concurrent stdout/stderr capture, byte-offset polling, exit status, cancellation, server-side timeout.
- Four concurrent jobs by default; 4 MiB retained per output stream. Excess bytes are drained and counted.
- Mutual shared-key authentication, AES-256-GCM encryption, replay protection, bounded GATT framing.
- Mutation deduplication during one server run; stale server-run IDs are rejected after a restart.

The configured root limits the dedicated filesystem tools and the initial command working directory. **It is not a sandbox for arbitrary commands.** Commands run as the macOS user running the server, with that account's permissions and privacy grants. For a narrower command boundary, run the server under a dedicated macOS account. Set `allowCommands` to `false` to disable command tools.

## Diagnostic client

The build creates a client app bundle to provide Bluetooth usage metadata, but its executable is a CLI:

```sh
dist/LaptopLinkClient.app/Contents/MacOS/link-client \
  --key /private/path/client.key
```

This discovers the service, authenticates, and prints `server.info` JSON. Use `--name 'Laptop Link'` to filter by advertised name if needed. The key authenticates the server; the name is only a discovery filter.

To execute a command, save a request containing the `bootID` from `server.info` and a new UUID from `uuidgen`:

```json
{
  "version": 1,
  "id": "A7A672AF-334D-4F1A-B6C4-B7353F2E9210",
  "bootID": "REPLACE-WITH-SERVER-BOOT-ID",
  "method": "exec.start",
  "params": {
    "executable": "/usr/bin/sw_vers",
    "args": [],
    "cwd": ".",
    "timeout_seconds": 30
  }
}
```

```sh
dist/LaptopLinkClient.app/Contents/MacOS/link-client \
  --key /private/path/client.key --request command.json
```

The result contains a `job_id`. Submit `exec.poll` with that job ID to receive stdout, stderr, and status. Output `data` fields are base64 so binary data and split UTF-8 sequences remain intact. See the complete [RPC reference](docs/PROTOCOL.md).

Save mutation request JSON **before** submitting it. If the connection drops, retry the identical request with the same UUID and `bootID`; the server returns the saved result without repeating the operation. Never replace an old `bootID` to blindly retry a command after restart. Its outcome may be unknown.

## Development and verification

```sh
./scripts/check.sh
./scripts/package-apps.sh
./scripts/source-archive.sh
```

The default test script compiles a standalone executable and runs 17 checks without XCTest. Protocol checks exercise authentication/encryption/framing in memory; execution and file checks launch the actual server and communicate through its JSON-lines endpoint. They do not prove radio performance or macOS Bluetooth permission behavior on a second machine. Use the [two-Mac acceptance checklist](docs/SETUP.md#two-mac-acceptance-checklist) after copying.

The original 17 XCTest tests are retained for development environments with a working Swift Package Manager and XCTest installation: `./scripts/check.sh --swiftpm`. App packaging can also opt into SwiftPM using `./scripts/package-apps.sh --swiftpm`. The `.swift-version` and `Package.swift` files apply to that optional workflow; the default build does not read the manifest.

Direct build outputs are under `.build/direct/debug` and `.build/direct/release`. To choose a compiler explicitly, set `LINK_SWIFTC=/absolute/path/to/swiftc`. To choose an older installed SDK when the default requires a newer compiler, set `LINK_SDK=/absolute/path/to/MacOSX26.5.sdk`. Otherwise the SDK follows the active `xcode-select` directory (or a per-command `DEVELOPER_DIR` override), as does the C compiler. Build scripts print their compiler version and SDK path for troubleshooting.

Targets: `LinkProtocol` (protocol/crypto), `LinkServerKit` (operations), `ProcessSupport` (POSIX spawn), `LinkBluetooth` (Core Bluetooth), `LinkServerApp` (menu bar app/stdio), `LinkClientApp` (diagnostic CLI).

## Current limits

- One RPC in flight per BLE session; up to four subscribed peers. Idle authenticated sessions expire after five minutes.
- BLE request chunks use ATT writes with response. Notifications use Core Bluetooth flow control. Application-level responses confirm operations; on a lost response, reconnect and replay the same mutation identity. There is no automatic retry of command submission.
- Job and upload recovery works across BLE reconnects while the server process remains alive. Restart recovery is deliberately not automatic. Job records and deduplication live in memory; output remains in the state directory for manual inspection.
- Noninteractive commands only. Stdin is `/dev/null`; no PTY, input streaming, password prompts, or persistent shell. Shell commands use `/bin/zsh -c`, without loading login profiles.
- Jobs own their process group. Remaining group members are killed when the leader exits. Programs that deliberately detach into a new process group/session are not contained; this is not an OS sandbox.
- Default limits: 128 jobs and 8192 mutation IDs per server run. Restart after finishing work when these limits are reached. Old state directories are retained; quit the server before manually removing unneeded run directories.
- File listings are paginated and can change between pages. Search is literal, bounded to five seconds/10000 entries, skips symlinks, and skips content files over 1 MiB or invalid UTF-8. File copy is for regular files; directory moves are supported.
- Atomic replacement protects against partial destination files. Hash checks detect ordinary concurrent edits, but are not an OS-level compare-and-swap against other processes. Path validation is not hardened against a hostile local process racing symlinks.
- App bundles are locally ad-hoc signed, not Developer ID notarized. macOS privacy prompts or Gatekeeper approval may be needed on the destination Mac. Rebuilding/re-signing can require Bluetooth permission again.

Apple APIs: [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth), [CryptoKit](https://developer.apple.com/documentation/cryptokit), [Bluetooth usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription). Toolchain: [Swift 6.3.3 release](https://forums.swift.org/t/announcing-swift-6-3-3/87888).
