#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
corner_test_dir=$(mktemp -d)
trap 'rm -rf "$corner_test_dir"' EXIT
swiftc -target arm64-apple-macos26.0 \
    Packages/AnchorUtilities/Sources/AnchorUtilities/UI/AnchorCorners.swift \
    tests/ConcentricCornerTests.swift -o "$corner_test_dir/check"
"$corner_test_dir/check"
