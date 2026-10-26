#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc Anchor/Managers/LockScreen/LockSoundAudio.swift tests/LockSoundAudioTests.swift -o "$out/check"
"$out/check" "$PWD/Anchor"
