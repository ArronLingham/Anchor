#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc Anchor/Managers/Display/LunarMessageStream.swift Anchor/Managers/Launcher/LauncherWidgetProfile.swift tests/LauncherExperienceTests.swift -o "$out/check"
"$out/check"
