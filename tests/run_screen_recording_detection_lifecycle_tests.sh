#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
sed -e '/^import Defaults$/d' -e 's/fileprivate func handleCaptureEvent/func handleCaptureEvent/' \
    Anchor/Managers/Display/ScreenRecordingManager.swift > "$output/ScreenRecordingManager.swift"
xcrun swiftc -swift-version 5 "$output/ScreenRecordingManager.swift" tests/ScreenRecordingDetectionLifecycleTests.swift -o "$output/check"
"$output/check"
