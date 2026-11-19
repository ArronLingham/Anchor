#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
weather_test_output=$(mktemp -d)
trap 'rm -rf "$weather_test_output"' EXIT
swiftc Anchor/Managers/LockScreen/WeatherDemandState.swift tests/WeatherDemandTests.swift \
  -o "$weather_test_output/check"
"$weather_test_output/check"
