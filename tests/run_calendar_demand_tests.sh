#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
sed '/^import Defaults$/d' Anchor/Managers/Productivity/CalendarManager.swift > "$output/CalendarManager.swift"
{
    printf '%s\n' 'import EventKit'
    sed -n '/^extension EKEventStore {/,/^\/\/ MARK: - Model Extensions/p' Anchor/Models/CalendarServiceProviding.swift
} > "$output/CalendarReminderFetch.swift"
xcrun swiftc -swift-version 5 "$output/CalendarManager.swift" "$output/CalendarReminderFetch.swift" tests/CalendarDemandTests.swift -o "$output/check"
"$output/check"
