#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -O -module-cache-path "$work/modules" Anchor/Managers/Productivity/ShelfFileActions.swift \
    tests/ShelfFileActionTests.swift -o "$work/check"
"$work/check" "$@"
