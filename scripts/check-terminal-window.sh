#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Opt-in: opens a local test window; optional argument captures only that window.
if [[ "${LINK_SKIP_BUILD:-0}" != 1 ]]; then /bin/bash scripts/compile.sh --debug; fi
ble_output="$PWD/.build/direct/debug"
ble_swiftc="${LINK_SWIFTC:-$(command -v swiftc)}"
ble_sdk="${LINK_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
"$ble_swiftc" -swift-version 6 -parse-as-library -Onone -sdk "$ble_sdk" \
    -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$ble_output/module-cache" \
    -I "$ble_output/modules" -I "$PWD/Sources/ProcessSupport/include" \
    Tests/AppKit/TerminalWindowChecks.swift Sources/LinkServerApp/TerminalWindow.swift \
    "$ble_output/libLinkServerKit.a" "$ble_output/libLinkProtocol.a" "$ble_output/libSwiftProtobuf.a" \
    "$ble_output/libSwiftTerm.a" "$ble_output/ProcessSupport.o" "$ble_output/TerminalProcess.o" \
    -o "$ble_output/terminal-window-checks"
"$ble_output/terminal-window-checks" "$@"
