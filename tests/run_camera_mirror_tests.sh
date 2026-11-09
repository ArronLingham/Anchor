#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
camera_test_output=$(mktemp -d)
trap 'rm -rf "$camera_test_output"' EXIT
swiftc Anchor/Managers/Tools/CameraMirrorSessionGate.swift tests/CameraMirrorSessionGateTests.swift \
  -o "$camera_test_output/check"
"$camera_test_output/check"
