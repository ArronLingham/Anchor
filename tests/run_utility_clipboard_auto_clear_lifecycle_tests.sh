#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
folder=Packages/AnchorUtilities/Sources/AnchorUtilities/Services/Clipboard
python3 - "$folder/ClipboardAutoClearService.swift" "$output/AutoClear.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text().replace("import AppKit\n", "")
for old, new in {
    "NSWorkspace": "FixtureWorkspace",
    "NotificationCenter": "FixtureNotificationCenter",
    "NSPasteboard.general": "FixturePasteboard.shared",
    "GeneralPasteboardAccess": "FixtureAccess",
}.items():
    source = source.replace(old, new)
source += """
extension ClipboardAutoClearService {
    func tickForTest() { tick() }
}
"""
Path(sys.argv[2]).write_text(source)
PY
xcrun swiftc -swift-version 5 "$output/AutoClear.swift" "$folder/ClipboardAutoClearSupport.swift" tests/UtilityClipboardAutoClearLifecycleTests.swift -o "$output/check"
"$output/check"
