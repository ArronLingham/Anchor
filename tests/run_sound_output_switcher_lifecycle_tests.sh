#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/SwitchMethods.swift" <<'PY'
from pathlib import Path
import sys

root = Path("Packages/AnchorUtilities/Sources/AnchorUtilities/Services")
service = (root / "Audio/SoundOutputSwitcher.swift").read_text()
gate = (root / "Clipboard/ClipboardHistorySupport.swift").read_text()
method = service[service.index("    private func scheduleSwitch()"):service.index("    private func registerHotkey()")]
method = method.replace("private func", "func").replace("DispatchQueue.main.async", "enqueue")
lock = gate[gate.index("final class ClipboardPresentationGate"):gate.index("/// How the history window")]
Path(sys.argv[1]).write_text("import Foundation\n" + lock + "extension SwitchFixture {\n" + method + "}\n")
PY
xcrun swiftc -swift-version 5 "$output/SwitchMethods.swift" tests/SoundOutputSwitcherLifecycleTests.swift -o "$output/check"
"$output/check"
