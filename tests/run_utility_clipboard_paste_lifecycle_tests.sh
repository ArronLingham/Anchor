#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
fixture=Packages/AnchorUtilities/Sources/AnchorUtilities/Services/Clipboard
python3 - "$fixture/ClipboardHistorySupport.swift" "$output/Paste.swift" \
    "$fixture/ClipboardHistoryService.swift" \
    Packages/AnchorUtilities/Sources/AnchorUtilities/Services/CommandBar/CommandBarCatalog.swift <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
gate = source[source.index("final class ClipboardPresentationGate"):source.index("/// How the history window")]
paste = source[source.index("enum ClipboardHistoryPaste {"):]
for old, new in {
    "NSRunningApplication": "FixtureApp",
    "NSWorkspace": "FixtureWorkspace",
    "CGEventSource": "FixtureEventSource",
    "CGEvent(": "FixtureKeyboardEvent(",
    "NSPasteboard.general": "FixturePasteboard.shared",
    "AXIsProcessTrusted()": "FixtureSettings.accessibility",
    "IsSecureEventInputEnabled()": "FixtureSettings.secureInput",
    "NSSound.beep()": "FixtureSettings.beep()",
    "GeneralPasteboardAccess": "FixtureAccess",
}.items():
    paste = paste.replace(old, new)
history = Path(sys.argv[3]).read_text()
copy = history[history.index("    func copy(_ entry:"):history.index("    /// What to put on the pasteboard")]
copy = copy.replace("GeneralPasteboardAccess", "FixtureAccess").replace("NSPasteboard.general", "FixturePasteboard.shared")
catalog = Path(sys.argv[4]).read_text()
start = catalog.index("                run: { _ in\n", catalog.index('id: "action.clipboardClearRecent"'))
body = catalog[start:].split("\n", 1)[1].split("                }))", 1)[0]
confirmation = "func confirmClearInCommandBar(clipboardTicket: UUID, recentIDs: [UUID: Date]) {\n" + body + "}\n"
Path(sys.argv[2]).write_text("import AppKit\nimport Carbon.HIToolbox\n" + gate + paste + "\n" + confirmation
                            + "\nextension ClipboardHistoryService {\n" + copy + "}\n")
PY
xcrun swiftc -swift-version 5 "$output/Paste.swift" "$fixture/ClipboardHistoryWrite.swift" tests/UtilityClipboardPasteLifecycleTests.swift -o "$output/check"
"$output/check"
