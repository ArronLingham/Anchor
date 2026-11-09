#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ai_test_output=$(mktemp -d)
trap 'rm -rf "$ai_test_output"' EXIT
swiftc Anchor/Managers/Assistant/AIAssistantSession.swift tests/AIAssistantSessionTests.swift \
  -o "$ai_test_output/check"
"$ai_test_output/check"
