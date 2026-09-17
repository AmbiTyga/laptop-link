#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

link_mode=release
link_tests=false
for link_argument in "$@"; do
    case "$link_argument" in
        --debug) link_mode=debug ;;
        --tests) link_mode=debug; link_tests=true ;;
        *) echo "Usage: $0 [--debug] [--tests]" >&2; exit 2 ;;
    esac
done

# Only the compiler and SDK are used. Never invoke swift, swift-package, SwiftPM, or Xcode's test runner.
link_swiftc="${LINK_SWIFTC:-$(command -v swiftc)}"
link_sdk="${LINK_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
if [[ ! -d "$link_sdk" || ! -f "$link_sdk/SDKSettings.json" ]]; then
    echo "Invalid macOS SDK directory: $link_sdk" >&2
    echo 'Set LINK_SDK to an installed SDK directory, such as /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk.' >&2
    exit 1
fi
link_clang="$(xcrun --sdk macosx --find clang)"
link_version="$("$link_swiftc" --version)"
if [[ "$link_version" != *'Swift version 6.3.3'* ]]; then
    echo "Expected the existing Swift 6.3.3 compiler; got: $link_version" >&2
    echo 'Set LINK_SWIFTC to the full path of your Swift 6.3.3 swiftc executable.' >&2
    exit 1
fi
link_arch="$(uname -m)"
case "$link_arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $link_arch" >&2; exit 1 ;; esac
link_target="$link_arch-apple-macosx13.0"
link_output="$PWD/.build/direct/$link_mode"
mkdir -p "$link_output/modules" "$link_output/module-cache"
link_flags=(-swift-version 6 -parse-as-library -sdk "$link_sdk" -target "$link_target"
    -module-cache-path "$link_output/module-cache" -I "$link_output/modules"
    -I "$PWD/Sources/ProcessSupport/include")
if [[ "$link_mode" == debug ]]; then link_flags+=(-Onone -g); else link_flags+=(-O); fi

echo "Direct build ($link_mode): $link_swiftc"
echo "$link_version"
echo "SDK: $link_sdk"
"$link_clang" -isysroot "$link_sdk" -target "$link_target" -O2 \
    -I Sources/ProcessSupport/include -c Sources/ProcessSupport/ProcessSupport.c -o "$link_output/ProcessSupport.o"

link_module() {
    local name="$1"
    echo "Compiling $name"
    "$link_swiftc" "${link_flags[@]}" -module-name "$name" -emit-module \
        -emit-module-path "$link_output/modules/$name.swiftmodule" \
        -emit-library -static "Sources/$name/"*.swift -o "$link_output/lib$name.a"
}
echo 'Compiling vendored SwiftProtobuf'
"$link_swiftc" "${link_flags[@]}" -package-name SwiftProtobuf -module-name SwiftProtobuf -emit-module \
    -emit-module-path "$link_output/modules/SwiftProtobuf.swiftmodule" -emit-library -static \
    Vendor/SwiftProtobuf/Sources/*.swift -o "$link_output/libSwiftProtobuf.a"
link_module LinkProtocol
link_module LinkServerKit
link_module LinkBluetooth

link_libraries=("$link_output/libLinkServerKit.a" "$link_output/libLinkBluetooth.a"
    "$link_output/libLinkProtocol.a" "$link_output/libSwiftProtobuf.a" "$link_output/ProcessSupport.o")
echo 'Linking link-server'
"$link_swiftc" "${link_flags[@]}" -module-name LinkServerApp Sources/LinkServerApp/*.swift \
    "${link_libraries[@]}" -o "$link_output/link-server"
echo 'Linking link-client'
"$link_swiftc" "${link_flags[@]}" -module-name LinkClientApp Sources/LinkClientApp/*.swift \
    "${link_libraries[@]}" -o "$link_output/link-client"
if [[ "$link_tests" == true ]]; then
    echo 'Compiling standalone checks (no XCTest or SwiftPM)'
    "$link_swiftc" "${link_flags[@]}" -module-name LinkStandaloneChecks Tests/Standalone/*.swift \
        "${link_libraries[@]}" -o "$link_output/link-checks"
fi
echo "Build complete: $link_output"
