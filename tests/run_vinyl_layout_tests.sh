#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'if test -f "$output/check"; then unlink "$output/check"; fi; rmdir "$output"' EXIT
xcrun swiftc Anchor/Components/Vinyl/VinylLayout.swift tests/VinylLayoutTests.swift -o "$output/check"
"$output/check"
