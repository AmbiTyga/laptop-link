#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == --swiftpm ]]; then
    shift
    mkdir -p .build/module-cache .build/cache
    export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
    export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
    exec swift test --disable-sandbox --cache-path "$PWD/.build/cache" "$@"
fi
if [[ $# -ne 0 ]]; then echo "Usage: $0 [--swiftpm SwiftPM-options...]" >&2; exit 2; fi
/bin/bash ./scripts/compile.sh --tests
exec .build/direct/debug/link-checks
