#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/FinderMethods.swift" <<'PY'
from pathlib import Path
import sys

source = Path("Packages/AnchorUtilities/Sources/AnchorUtilities/Services/Finder/FinderCutPaste.swift").read_text()
def methods(start, end):
    return source[source.index(start):source.index(end, source.index(start))]

image = methods("    private enum ImagePasteResult", "    private func postNormalPaste(")
publish = methods("    private static func publishImage(", "    /// True when the keyboard focus")
completion = methods("    private func finishPaste(", "    private enum MoveOutcome")
reset = methods("    private func resetCutState(", "    private func scheduleResultDismiss()")
methods = (image + publish + completion + reset).replace("private ", "")
methods = methods.replace("NSPasteboard.general", "pasteboard").replace("NSSound.beep()", "beepCount += 1")
Path(sys.argv[1]).write_text("import Foundation\nextension FinderFixture {\n" + methods + "}\n")
PY
xcrun swiftc -swift-version 5 "$output/FinderMethods.swift" tests/FinderCutPasteDisableLifecycleTests.swift -o "$output/check"
"$output/check"
