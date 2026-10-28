#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path "$work/modules" \
  Anchor/Models/DisplayLinkSupport.swift \
  Anchor/Managers/Display/DisplayLinkHardware.swift \
  tests/DisplayLinkSupportTests.swift -o "$work/check"
"$work/check" "$@"
