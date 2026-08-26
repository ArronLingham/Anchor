#!/usr/bin/env bash
#
# Compiles the real FuzzyMatcher and CalculatorAction and runs assertions
# against them. Both are pure and import only Foundation, so no stubs are
# needed — unlike the watcher tests, which need LoggerStub.
#
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
matcher="$repo/Anchor/managers/Launcher/FuzzyMatcher.swift"
calculator="$repo/Anchor/managers/Launcher/CalculatorAction.swift"
test_src="$repo/tests/LauncherTests.swift"

for f in "$matcher" "$calculator" "$test_src"; do
  [[ -f "$f" ]] || { echo "missing source: $f" >&2; exit 1; }
done

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

swiftc -O "$matcher" "$calculator" "$test_src" -o "$out/launchertests"
"$out/launchertests"
