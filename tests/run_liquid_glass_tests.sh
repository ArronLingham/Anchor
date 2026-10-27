#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
glass_test_dir=$(mktemp -d)
trap 'rm -rf "$glass_test_dir"' EXIT
swiftc -target arm64-apple-macos26.0 \
    Packages/AnchorUtilities/Sources/AnchorUtilities/UI/AnchorCorners.swift \
    Packages/AnchorUtilities/Sources/AnchorUtilities/UI/AnchorGlass.swift \
    tests/LiquidGlassRenderingTests.swift -o "$glass_test_dir/check"
"$glass_test_dir/check"
