#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output" <<'PY'
from pathlib import Path
import sys

services = Path("Packages/AnchorUtilities/Sources/AnchorUtilities/Services")
output = Path(sys.argv[1])
source = (services / "WindowLayout/WindowLayoutService.swift").read_text()
start = source.index("    static func captureAvailability()")
end = source.index("    @Published", start)
methods = source[start:end]
(output / "LayoutMethods.swift").write_text("import Foundation\nextension LayoutFixture {\n" + methods + "}\n")
support = (services / "Clipboard/ClipboardHistorySupport.swift").read_text()
start = support.index("final class ClipboardPresentationGate")
end = support.index("/// How the history window", start)
(output / "Gate.swift").write_text("import Foundation\n" + support[start:end])
session = (services / "SessionActivity.swift").read_text()
session = session.replace("static let shared = SessionActivity()", "static let shared = SessionActivity(center: sessionNotifications, initialIsActive: { true })")
(output / "SessionActivity.swift").write_text(session + "\nlet sessionNotifications = NotificationCenter()\n")
PY
swiftc -swift-version 5 "$output/LayoutMethods.swift" "$output/Gate.swift" "$output/SessionActivity.swift" Packages/AnchorUtilities/Sources/AnchorUtilities/Services/SessionActivitySupport.swift tests/WindowLayoutDeferredActionTests.swift -o "$output/check"
"$output/check"
