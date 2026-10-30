#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O Anchor/Managers/Launcher/FuzzyMatcher.swift Anchor/Managers/Launcher/LauncherSearch.swift tests/LauncherSearchTests.swift -o "$out/searchtests"
"$out/searchtests"
