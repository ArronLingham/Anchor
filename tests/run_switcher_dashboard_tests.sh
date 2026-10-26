#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc Anchor/Models/AppSwitcherPointerSelection.swift Anchor/Models/DashboardLayout.swift Anchor/Models/LauncherAppVisibility.swift Anchor/Models/LauncherCommandIntent.swift Anchor/Models/LockScreenEventPolicy.swift tests/SwitcherDashboardTests.swift -o "$out/check"
"$out/check"
