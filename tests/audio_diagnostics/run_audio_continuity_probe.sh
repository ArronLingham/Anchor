#!/bin/bash
# Regression checks compiled from production queue, fade, mapper and EQ sources.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 "$repo/tests/audio_diagnostics/audio_continuity_source_probe.py" "$work/main.swift"
swiftc -O \
  "$repo/Packages/AnchorUtilities/Sources/AnchorUtilities/Services/Audio/AudioFrameContinuity.swift" \
  "$repo/Packages/AnchorUtilities/Sources/AnchorUtilities/Services/Audio/MixerRender.swift" \
  "$repo/Anchor/Audio/PerApp/Types/BiquadProcessable.swift" \
  "$repo/Anchor/Audio/PerApp/EQ/BiquadProcessor.swift" \
  "$repo/Anchor/Audio/PerApp/EQ/EQProcessor.swift" \
  "$repo/Anchor/Audio/PerApp/EQ/BiquadMath.swift" \
  "$repo/Anchor/Audio/PerApp/Models/EQSettings.swift" \
  "$repo/Anchor/Audio/PerApp/Models/AutoEQProfile.swift" \
  "$repo/Anchor/Audio/PerApp/Engine/SoftLimiter.swift" \
  "$work/main.swift" -o "$work/probe"
"$work/probe"
