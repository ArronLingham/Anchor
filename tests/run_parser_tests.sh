#!/bin/bash
# Unit tests for ClaudeLimitParser.
#
# The parser is pure Foundation with no app dependencies, so it compiles
# standalone. That keeps these tests runnable without adding a unit-test target
# to Anchor.xcodeproj (which has only a UI-test target) and without a
# full app build.
#
#   ./tests/run_parser_tests.sh
#
# Compiles the REAL source file, not a copy, so the tests cannot drift from it.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$repo/Anchor/managers/ClaudeUsage/ClaudeLimitParser.swift"
test_src="$repo/tests/ClaudeLimitParserTests.swift"

[[ -f "$src" ]] || { echo "missing source: $src" >&2; exit 1; }

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

swiftc -O "$src" "$test_src" -o "$out/parsertests"
"$out/parsertests"
