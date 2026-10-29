#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
icon_test_output=$(mktemp -d)
trap 'rm -rf "$icon_test_output"' EXIT
swiftc -O Anchor/Managers/Launcher/AppIconCache.swift tests/AppIconCacheTests.swift -o "$icon_test_output/check"
"$icon_test_output/check"
