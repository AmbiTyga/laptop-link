#!/bin/bash
set -euo pipefail
link_repo="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$link_repo/scripts/setup.py" "$@"
