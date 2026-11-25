#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
sed -e '/^import Defaults$/d' -e 's/NSEvent/MouseFixture/g' -e 's/NSScreen/DisplayFixture/g' \
    Anchor/Managers/Launcher/LauncherHotCornerMonitor.swift > "$output/LauncherHotCornerMonitor.swift"
sed -e '/^import Defaults$/d' -e '/^import KeyboardShortcuts$/d' \
    -e 's/private func handle(/func handle(/' \
    -e 's/guard AXIsProcessTrusted() else/guard ProcessInfo.processInfo.arguments.contains("--allow-tap") else/' \
    Anchor/Managers/Input/SystemNavigationShortcutManager.swift > "$output/SystemNavigationShortcutManager.swift"
xcrun swiftc -swift-version 5 Anchor/Models/SystemNavigationShortcut.swift "$output/"*.swift tests/NavigationDisablementTests.swift -o "$output/check"
"$output/check"
