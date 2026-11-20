#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
swiftc -swift-version 5 Packages/AnchorUtilities/Sources/AnchorUtilities/Services/DockPreview/DockAutohideHold.swift tests/DockAutohideRecoveryTests.swift -o "$output/check"
"$output/check"
