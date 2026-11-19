#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
translation_manager_test_output=$(mktemp -d)
trap 'rm -rf "$translation_manager_test_output"' EXIT
swiftc -swift-version 5 -emit-module -emit-library -module-name Defaults tests/LyricsTranslationFakeDefaults.swift -o "$translation_manager_test_output/libDefaults.dylib" -emit-module-path "$translation_manager_test_output/Defaults.swiftmodule"
swiftc -swift-version 5 -I "$translation_manager_test_output" -L "$translation_manager_test_output" -lDefaults -Xlinker -rpath -Xlinker "$translation_manager_test_output" Anchor/Managers/Media/LyricsLookupGate.swift Anchor/Managers/Audio/LyricsTranslationCoordinator.swift Anchor/Managers/Audio/LyricsTranslator.swift tests/LyricsTranslationManagerTests.swift -o "$translation_manager_test_output/check"
"$translation_manager_test_output/check"
swiftc -swift-version 5 -typecheck -I "$translation_manager_test_output" Anchor/Managers/Media/LyricsLookupGate.swift Anchor/Managers/Audio/LyricsTranslationCoordinator.swift Anchor/Managers/Audio/LyricsTranslator.swift Anchor/Components/Music/SyncedLyricsList.swift tests/LyricsTranslationManagerTests.swift
