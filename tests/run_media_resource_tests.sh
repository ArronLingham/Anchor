#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
media_test_output=$(mktemp -d)
trap 'rm -rf "$media_test_output"' EXIT
swiftc -swift-version 5 Anchor/Models/PlaybackState.swift Anchor/MediaControllers/MediaControllerProtocol.swift \
  'Anchor/MediaControllers/YouTube Music Controller/YouTubeMusicModels.swift' \
  'Anchor/MediaControllers/YouTube Music Controller/YouTubeMusicController.swift' \
  tests/YouTubeMusicResourceTests.swift -o "$media_test_output/check"
"$media_test_output/check"
