#!/bin/bash
# End-to-end tests for ClaudeTranscriptWatcher.
#
# Compiles the real watcher and parser against a stub Logger, then drives them
# over a temporary directory. No unit-test target and no app build required, and
# nothing touches the real ~/.claude tree.
#
#   ./tests/run_watcher_tests.sh
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

swiftc -O \
  "$repo/Anchor/managers/ClaudeUsage/ClaudeLimitParser.swift" \
  "$repo/Anchor/managers/ClaudeUsage/ClaudeTranscriptWatcher.swift" \
  "$repo/tests/support/LoggerStub.swift" \
  "$repo/tests/ClaudeTranscriptWatcherTests.swift" \
  -o "$out/watchertests"

"$out/watchertests"
