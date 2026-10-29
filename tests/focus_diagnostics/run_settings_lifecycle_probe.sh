#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 "$repo/tests/focus_diagnostics/settings_lifecycle_probe.py" "$work/main.swift"
swiftc -swift-version 5 "$work/main.swift" -o "$work/probe"
"$work/probe"
