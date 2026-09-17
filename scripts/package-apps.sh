#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p dist
if [[ "${1:-}" == --swiftpm ]]; then
    shift
    mkdir -p .build/module-cache .build/cache
    export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
    export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
    swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache" "$@"
    binary_dir=$(swift build -c release --disable-sandbox --show-bin-path "$@")
else
    if [[ $# -ne 0 ]]; then echo "Usage: $0 [--swiftpm SwiftPM-options...]" >&2; exit 2; fi
    /bin/bash ./scripts/compile.sh
    binary_dir="$PWD/.build/direct/release"
fi

make_bundle() {
    local bundle="$1" executable="$2" identifier="$3" display_name="$4"
    mkdir -p "$bundle/Contents/MacOS"
    cp "$binary_dir/$executable" "$bundle/Contents/MacOS/$executable"
    mkdir -p "$bundle/Contents/Resources/SwiftTerm"
    cp Vendor/SwiftTerm/LICENSE "$bundle/Contents/Resources/SwiftTerm/"
    mkdir -p "$bundle/Contents/Resources/SwiftProtobuf"
    cp Vendor/SwiftProtobuf/PrivacyInfo.xcprivacy "$bundle/Contents/Resources/SwiftProtobuf/"
    cp Vendor/SwiftProtobuf/LICENSE.txt "$bundle/Contents/Resources/SwiftProtobuf/"
    cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$identifier</string>
  <key>CFBundleName</key><string>$display_name</string>
  <key>CFBundleDisplayName</key><string>$display_name</string>
  <key>CFBundleExecutable</key><string>$executable</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Connect your Macs over Bluetooth to exchange files and execute commands you request.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
    /usr/bin/codesign --force --sign - "$bundle"
    /usr/bin/codesign --verify --strict "$bundle"
}

make_bundle 'dist/LaptopLinkServer.app' link-server local.laptop-link.server 'Laptop Link Server'
make_bundle 'dist/LaptopLinkClient.app' link-client local.laptop-link.client 'Laptop Link Client'
echo 'Built dist/LaptopLinkServer.app and dist/LaptopLinkClient.app'
echo 'The client is a command-line diagnostic inside an app bundle; run Contents/MacOS/link-client --help.'
