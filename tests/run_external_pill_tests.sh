#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swiftc Anchor/Models/ExternalPillPolicy.swift tests/ExternalPillPolicyTests.swift -o "$WORK/tests"
"$WORK/tests"
