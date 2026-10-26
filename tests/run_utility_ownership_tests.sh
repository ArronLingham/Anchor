#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
utility_test_output=$(mktemp -d)
trap 'rm -rf "$utility_test_output"' EXIT
swiftc Anchor/Models/UtilityOwnership.swift tests/UtilityOwnershipTests.swift -o "$utility_test_output/check"
"$utility_test_output/check"
