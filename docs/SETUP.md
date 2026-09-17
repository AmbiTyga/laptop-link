# Remote Mac setup

## Prerequisites

- macOS 13 or newer for the app; Bluetooth LE support on both Macs. Hardware support and throughput must be checked on the actual pair of Macs.
- To build source: the existing Swift 6.3.3 compiler plus Command Line Tools (or Xcode) containing the macOS SDK and clang. The default build/test scripts do not use Swift Package Manager or XCTest. A full Xcode app is not required.
- A logged-in user session. This release is a menu bar app, not a boot-time LaunchDaemon. Keep the machine awake while using it. Nothing is installed as a login item automatically.

If your current compiler already reports Swift 6.3.3, keep using it:

```sh
swiftc --version
xcrun --sdk macosx --show-sdk-path
```

The scripts bypass `swift-package` entirely, including when it crashes with a missing `BuildServerProtocol` symbol. They cannot repair a broken compiler or missing SDK, so a failure at that later stage should be diagnosed from the build output.

If the default SDK is newer than your compiler supports, choose an older installed SDK. For the remote Mac reporting Swift 6.3.3, a macOS 27.0 SDK built with Swift 6.4, and an installed macOS 26.5 SDK, try:

```sh
export LINK_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
./scripts/check.sh 2>&1 | tee test-output.txt
```

The build must print that SDK path. Keep the same `LINK_SDK` setting when running `./scripts/package-apps.sh`. This only selects an existing SDK for this project; it does not change the system-wide developer directory. Both the C and Swift compiler receive the explicit SDK path. A valid path alone does not guarantee compatibility; the build checks whether the selected compiler can actually use its interfaces.

Only if Swift 6.3.3 is missing, the official Swiftly setup is described at https://www.swift.org/install/macos/swiftly/. After installing Swiftly:

```sh
swiftly install --use 6.3.3
swift --version
```

If the compiler is missing on an offline Mac, download the **Swift 6.3.3 macOS toolchain package** from https://www.swift.org/install/macos/ and copy the installer along with the source. Install it and put its `usr/bin` directory on PATH, or set `LINK_SWIFTC` to its `swiftc` path. No replacement download is required just because Swift Package Manager is broken.

## Build and launch

```sh
cd /path/to/laptop-link
./scripts/check.sh
./scripts/package-apps.sh
open dist/LaptopLinkServer.app
```

The default direct build targets the build Mac's architecture. Build on the remote Mac if its architecture differs. Direct binaries appear in `.build/direct/release`; the test script builds `.build/direct/debug/link-checks` and the server it exercises. App bundles still appear in `dist`.

If you have a working SwiftPM/XCTest environment, the original test suite is available via `./scripts/check.sh --swiftpm`. A universal app build can be requested through the optional SwiftPM path: `./scripts/package-apps.sh --swiftpm --arch arm64 --arch x86_64`. Verify that configuration separately; the default direct builder produces one native architecture.

To save diagnostics for sharing:

```sh
./scripts/check.sh 2>&1 | tee test-output.txt
```

The last summary should say `20/20 standalone checks passed; 0 failed.` If piping through `tee` in an automated script, enable `set -o pipefail` so a test failure is not masked by tee's success. Run `./scripts/package-apps.sh` after the checks pass.

Alternatively, copy the already-built `dist/LaptopLinkServer.app` to an Apple Silicon Mac with a compatible OS; no compiler is needed to run the app. Keep the whole `.app` bundle intact, using Finder, `ditto`, or a zip that preserves bundle contents.

First launch asks for the workspace folder. Configuration and a fresh key are generated on that Mac. Approve Bluetooth access when macOS prompts. If denied, use **System Settings → Privacy & Security → Bluetooth** to enable access for the app (or its launching terminal, depending on how it was launched). If files are inaccessible, grant access only to the folders/privacy categories needed; command execution cannot bypass macOS privacy controls.

The menu should show **Advertising as Laptop Link**. Use **Show configuration folder** to locate the key and configuration. Quit before editing configuration, then relaunch.

## Guided setup and key sharing

With Python 3.9+ installed, run:

```sh
./scripts/setup.sh
```

If the app is missing, setup builds it using the same toolchain settings as `package-apps.sh`. If configuration is missing, it prompts for an existing workspace and uses the app's initializer to generate a random 32-byte `client.key`. Existing configuration and its key are reused without rotation. An existing app bundle is reused; rebuild it explicitly when upgrading source.

Setup launches the app, offers the local IPv4 addresses, and reserves five available TCP ports between 8000 and 8999. Enter one of the listed port numbers (Enter selects the first). It prints the selected IP, port, and full download URL:

```text
http://192.168.1.15:8000/client.key
```

The original key stays at the configured `keyFile`. A private, Git-ignored copy lives at `.key-share/client.key` inside the repository while sharing. This folder is excluded from the source archive. The HTTP helper serves only `/client.key`, with no directory listing or access to other repository files. It runs in the foreground until Ctrl+C, then removes the copy. A forced kill or power loss may leave the ignored copy behind; remove `.key-share/client.key` manually in that case.

HTTP key transfer is unencrypted and anyone who can reach that endpoint can download the enrollment key while it is running. Use a trusted LAN and stop sharing after enrollment. Allow an incoming connection if macOS asks. A free port does not establish network reachability across firewalls or guest Wi-Fi isolation.

On the controlling Mac, `laptop-link-mcp/scripts/setup.sh` asks for this IP, port, and a safe local key name. It downloads `/client.key`, validates the byte count, and remembers the saved key. Then stop this HTTP helper; the BLE app continues running independently.

Options:

```sh
# New configuration: choose the workspace without a prompt.
./scripts/setup.sh --root /absolute/workspace

# Reuse an explicitly chosen configuration, choose an IP, and leave app launch to you.
./scripts/setup.sh --config /private/config/server.json --bind 192.168.1.15 --no-launch
```

`--root` is only valid for a new configuration. `--bind` must identify a local IPv4 interface. Run helper checks with `python3 -m unittest discover -s Tests/Setup -v`; these use temporary dummy keys and loopback HTTP, not your enrollment key.

## Optional command-line initialization

This avoids the folder picker:

```sh
dist/LaptopLinkServer.app/Contents/MacOS/link-server \
  --init --root /absolute/path/to/workspace
open dist/LaptopLinkServer.app
```

To keep configuration elsewhere:

```sh
dist/LaptopLinkServer.app/Contents/MacOS/link-server \
  --init --root /absolute/workspace --config /private/config/server.json
open dist/LaptopLinkServer.app --args --config /private/config/server.json
```

The root directory must exist. Initialization refuses to overwrite existing configuration or key files. The configuration uses absolute paths; if copying an existing config, update `root`, `stateDirectory`, and `keyFile` to destination paths. Prefer fresh initialization on the remote Mac.

## Configuration

The initializer writes all fields; retain them when editing:

```json
{
  "name": "Laptop Link",
  "root": "/Users/you/workspace",
  "stateDirectory": "/Users/you/Library/Application Support/LaptopLink/state",
  "keyFile": "/Users/you/Library/Application Support/LaptopLink/client.key",
  "allowCommands": true,
  "maximumConcurrentJobs": 4,
  "maximumJobsPerRun": 128,
  "maximumTimeoutSeconds": 3600,
  "outputBytesPerStream": 4194304,
  "maximumUploadBytes": 67108864
}
```

Keep `client.key` mode `600`. It contains raw binary bytes, not a password or base64 text. Transfer it privately to the client Mac. For key rotation, quit the server, generate a fresh 32-byte cryptographically random key, replace the key file with mode 600, update the client, and relaunch. Previously enrolled clients then lose access. V1 has one shared enrollment key, not independent per-client revocation.

Each server run has its own state subdirectory. Command output files are mode 600 under `jobs/<spool-id>/stdout` and `stderr`; upload temporary files are under `uploads`. Keep state outside the remotely exposed workspace. State directory names are boot IDs; spool directory IDs are separate from public job IDs.

## Local diagnostic mode

```sh
dist/LaptopLinkServer.app/Contents/MacOS/link-server --stdio --config /path/server.json
```

Send one compact RPC JSON object per line. Read `server.info` first and use its `bootID` in subsequent requests. This mode executes real operations, uses no Bluetooth, and intentionally trusts the local process's stdin. It never opens a network socket. End stdin to shut it down and kill its active jobs. The server lock prevents running BLE and stdio servers against the same state directory simultaneously.

## Two-Mac acceptance checklist

1. Launch the server, grant Bluetooth access, and confirm advertising status.
2. On the other Mac, run the bundled diagnostic client with the transferred enrollment key. Confirm `server.info` reports the expected name and root.
3. Submit `fs.write`, then `fs.read` and `fs.hash`. Verify exact binary bytes and SHA-256.
4. Upload a file larger than a BLE payload through `upload.begin/chunk/commit`; compare its hash on both Macs.
5. Run a command that emits stdout and stderr and exits nonzero. Poll both streams to EOF and verify the exit code.
6. Run `sleep 30` with `timeout_seconds: 2`; confirm `timed_out`. Separately cancel a long-running command and confirm `cancelled`.
7. Start a job, disconnect the client, then reconnect and poll the same job. Confirm its output remains available.
8. Replay an identical mutation request UUID and bootID; confirm it does not append twice or start a second job.
9. Restart the server and resend an old mutation. Confirm `server_changed` and no execution.
10. Test a wrong key, denied Bluetooth permission, Bluetooth off, and sleep/wake. Record measured transfer speed; no throughput claim is made by local tests.

For Claude, Codex, or another local MCP client, install [Laptop Link MCP](https://github.com/AmbiTyga/laptop-link-mcp) on the controlling laptop. It exposes file operations and command jobs over the same protocol and includes a portable Agent Skill. The remote server requires no additional Python runtime or MCP configuration.

## Upgrading the BLE wire format

Copy the entire updated source archive, including `Vendor` and `Protocol`, to a new directory. Build with the same Swift 6.3.3 compiler and compatible SDK as before. Generated Protobuf messages and their runtime are already included; no SwiftPM download or `protoc` installation is needed on this Mac.

The updated server accepts legacy JSON clients as well as Protobuf clients. Restarting the server creates a new boot ID: finish or cancel jobs and resolve pending mutations before replacing a running server. Never rewrite a pending request's boot ID to resubmit it after an upgrade. Enrollment keys remain usable; pass the existing configuration path when launching the replacement app.

The diagnostic client uses Protobuf by default. For an older server, pass `--wire json`. Laptop Link MCP's default `--wire auto` queries authenticated capabilities and reports its selection in the `transport.wire_format` field of status responses. Use `--wire protobuf` to require the new format.

## Terminal window

Rebuild the complete source archive to enable terminals. The server menu adds **New Terminal** and **Show Terminals**. Update the companion MCP too for its six `link_terminal_*` tools. See [interactive terminal setup and controls](TERMINALS.md). An older running server does not gain these methods until it is replaced and restarted.
