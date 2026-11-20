#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
homebrew_test_output=$(mktemp -d)
trap 'rm -rf "$homebrew_test_output"' EXIT
# Append test-only accessors in the same file. The manager implementation is copied unchanged.
cp Packages/AnchorUtilities/Sources/AnchorUtilities/Services/Homebrew/HomebrewManager.swift "$homebrew_test_output/HomebrewManager.swift"
cat >> "$homebrew_test_output/HomebrewManager.swift" <<'SWIFT'
extension HomebrewManager {
 func fixtureBrewPath(_ path: String) { brewPath = path }
 func fixtureRun(_ command: HomebrewCommand, completion: @escaping (Int32, String) -> Void) { run(command, completion: completion) }
 func fixtureTrust(brewPath: String, retry: @escaping () -> Void) {
  self.brewPath = brewPath
  presentUntrustedTap("fixture/tap", retry: retry)
  trustTapAndContinue()
 }
}
SWIFT
swiftc -swift-version 5 Packages/AnchorUtilities/Sources/AnchorUtilities/Services/Homebrew/HomebrewSupport.swift Packages/AnchorUtilities/Sources/AnchorUtilities/Services/BoundedProcessRunner.swift Packages/AnchorUtilities/Sources/AnchorUtilities/Integration/FeatureServiceSlot.swift "$homebrew_test_output/HomebrewManager.swift" tests/HomebrewLifecycleTests.swift -o "$homebrew_test_output/check"
"$homebrew_test_output/check"
