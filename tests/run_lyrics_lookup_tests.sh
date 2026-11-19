#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
lyrics_test_output=$(mktemp -d)
trap 'rm -rf "$lyrics_test_output"' EXIT
swiftc -swift-version 5 Anchor/Managers/Media/LyricsLookupGate.swift tests/LyricsLookupGateTests.swift -o "$lyrics_test_output/check"
"$lyrics_test_output/check"
