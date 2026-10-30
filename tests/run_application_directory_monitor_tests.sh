#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output_dir=$(mktemp -d)
trap 'rm -rf "$output_dir"' EXIT
swiftc Anchor/Managers/Launcher/ApplicationDirectoryMonitor.swift tests/ApplicationDirectoryMonitorTests.swift -o "$output_dir/check"
"$output_dir/check"
