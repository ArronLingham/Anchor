#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
scan_test_output=$(mktemp -d)
trap 'rm -rf "$scan_test_output"' EXIT
swiftc -swift-version 5 Packages/AnchorUtilities/Sources/AnchorUtilities/Services/BoundedProcessRunner.swift Packages/AnchorUtilities/Sources/AnchorUtilities/Services/AppUpdates/AppUpdateScanLifetime.swift tests/AppUpdateScanLifetimeTests.swift -o "$scan_test_output/check"
"$scan_test_output/check"
swiftc -swift-version 5 Packages/AnchorUtilities/Sources/AnchorUtilities/Services/BoundedProcessRunner.swift Packages/AnchorUtilities/Sources/AnchorUtilities/Services/InstalledApps.swift tests/AppUpdateDiscoveryTests.swift -o "$scan_test_output/discovery"
"$scan_test_output/discovery"
