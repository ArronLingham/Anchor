#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/PressMethods.swift" <<'PY'
from pathlib import Path
import sys

source = Path("Packages/AnchorUtilities/Sources/AnchorUtilities/Services/DockClick/DockClickService.swift").read_text()
def methods(start, end):
    return source[source.index(start):source.index(end, source.index(start))]

lifecycle = methods("    func syncWithPreferences()", "    /// Force-stops")
discard = methods("    private func discardPendingPress()", "    private func handle(type:")
press = methods("    private func handleDragged(", "    /// Applies a decided click")
deferred = methods("    private func acceptsDeferredAction(", "    // MARK: - Settling sweep")
methods = (lifecycle + discard + press + deferred).replace("private func", "func").replace("private var", "var").replace("private static var", "static var")
methods = methods.replace("down.post(tap: .cghidEventTap)", "replayedDown = true")
support = Path("Packages/AnchorUtilities/Sources/AnchorUtilities/Services/Clipboard/ClipboardHistorySupport.swift").read_text()
gate = support[support.index("final class ClipboardPresentationGate"):support.index("/// How the history window")]
Path(sys.argv[1]).write_text("import AppKit\n" + gate + "\nextension DockClickFixture {\n" + methods + "}\n")
PY
xcrun swiftc -swift-version 5 "$output/PressMethods.swift" tests/DockClickDisableLifecycleTests.swift -o "$output/check"
"$output/check"
