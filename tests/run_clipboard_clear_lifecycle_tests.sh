#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output" <<'PY'
from pathlib import Path
import sys

source = Path("Anchor/Managers/Clipboard/ClipboardToolsManager.swift").read_text()
source = source[:source.index("    // MARK: - Paste as plain text")] + source[source.index("    // MARK: - Auto clear"):]
source = source.replace("import AppKit\n", "").replace("import Defaults\n", "")
source = source.replace("NSPasteboard", "FixturePasteboard").replace("NSWorkspace", "FixtureWorkspace")
source = source.replace("NotificationCenter", "FixtureNotificationCenter")
source += """
extension ClipboardToolsManager {
    var timerForTest: Timer? { clearTimer }
}
"""
policy = Path("Anchor/Models/ProductivityWorkflows.swift").read_text()
policy = policy[policy.index("enum ClipboardCapturePolicy"):policy.index("struct ClipboardSearchDocument")]
output = Path(sys.argv[1])
(output / "ClipboardToolsManager.swift").write_text(source)
(output / "ClipboardCapturePolicy.swift").write_text("import Foundation\n" + policy)
PY
xcrun swiftc -swift-version 5 "$output"/{ClipboardToolsManager,ClipboardCapturePolicy}.swift tests/ClipboardClearLifecycleTests.swift -o "$output/check"
"$output/check"
