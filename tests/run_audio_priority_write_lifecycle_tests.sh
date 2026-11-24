#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/WriteMethods.swift" <<'PY'
from pathlib import Path
import sys

root = Path("Packages/AnchorUtilities/Sources/AnchorUtilities/Services")
service = (root / "Audio/AudioPriorityService.swift").read_text()
support = (root / "Clipboard/ClipboardHistorySupport.swift").read_text()
gate = support[support.index("final class ClipboardPresentationGate"):support.index("/// How the history window")]
methods = service[service.index("    private func syncWriteGates()"):].replace("private ", "")
Path(sys.argv[1]).write_text("import Foundation\n" + gate + "extension PriorityFixture {\n" + methods)
PY
xcrun swiftc -swift-version 5 "$output/WriteMethods.swift" tests/AudioPriorityWriteLifecycleTests.swift -o "$output/check"
"$output/check"
