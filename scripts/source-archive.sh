#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
# Explicit allowlist: never include local enrollment keys, config, build caches, or command output.
COPYFILE_DISABLE=1 /usr/bin/tar -czf dist/laptop-link-source.tar.gz \
    Package.swift .swift-version .gitignore README.md Sources Tests scripts docs Protocol Vendor
/usr/bin/shasum -a 256 dist/laptop-link-source.tar.gz > dist/laptop-link-source.tar.gz.sha256
echo 'Created dist/laptop-link-source.tar.gz'
