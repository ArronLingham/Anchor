#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
credential_test_output=$(mktemp -d)
trap 'rm -rf "$credential_test_output"' EXIT
swiftc Anchor/Managers/Assistant/AIAssistantCredential.swift tests/AIAssistantCredentialTests.swift -o "$credential_test_output/check"
"$credential_test_output/check"
