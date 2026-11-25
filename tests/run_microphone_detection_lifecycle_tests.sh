#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
xcrun swiftc -swift-version 5 Anchor/Managers/Audio/MicrophoneMonitor.swift tests/MicrophoneDetectionLifecycleTests.swift -o "$output/check"
"$output/check"
