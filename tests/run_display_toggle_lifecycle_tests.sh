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
source = (services / "Display/BrightnessService.swift").read_text()
methods = []
for signature in ("start()", "finishStopRestoration()", "acceptsDisplayToggle("):
    start = source.index("    private func " + signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    methods.append(source[start:end].replace("private func", "func", 1))
(output / "DisplayMethods.swift").write_text("import AppKit\nextension DisplayFixture {\n" + "\n".join(methods) + "\n}\n")
support = (services / "Clipboard/ClipboardHistorySupport.swift").read_text()
start = support.index("final class ClipboardPresentationGate")
end = support.index("/// How the history window", start)
(output / "Gate.swift").write_text("import Foundation\n" + support[start:end])
PY
swiftc -swift-version 5 "$output/DisplayMethods.swift" "$output/Gate.swift" tests/DisplayToggleLifecycleTests.swift -o "$output/check"
"$output/check"
