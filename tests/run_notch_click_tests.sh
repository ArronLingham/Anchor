#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
click_test_dir=$(mktemp -d)
trap 'rm -rf "$click_test_dir"' EXIT
swiftc Anchor/Models/NotchClickRegion.swift Anchor/Helpers/NotchInteractionSurface.swift \
    Anchor/Components/Notch/AnchorWindow.swift tests/NotchClickRoutingTests.swift \
    -o "$click_test_dir/check"
"$click_test_dir/check"
