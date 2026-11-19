#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
translation_test_output=$(mktemp -d)
trap 'rm -rf "$translation_test_output"' EXIT
swiftc -swift-version 5 Anchor/Managers/Media/LyricsLookupGate.swift Anchor/Managers/Audio/LyricsTranslationCoordinator.swift tests/LyricsTranslationCoordinatorTests.swift -o "$translation_test_output/check"
"$translation_test_output/check"
