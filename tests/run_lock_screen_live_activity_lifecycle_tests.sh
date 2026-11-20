#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
overlay_test_output=$(mktemp -d)
trap 'rm -rf "$overlay_test_output"' EXIT
python3 - "$overlay_test_output/OverlayMethods.swift" <<'PY'
from pathlib import Path
import sys

source = Path("Anchor/Managers/LockScreen/LockScreenLiveActivityWindowManager.swift").read_text()
start = source.index("    @discardableResult\n    private func beginPresentation()")
end = source.index("    func configure(viewModel:", start)
methods = source[start:end].replace("private func", "func")
Path(sys.argv[1]).write_text("import Foundation\nextension OverlayFixture {\n" + methods + "}\n")
PY
swiftc -swift-version 5 "$overlay_test_output/OverlayMethods.swift" tests/LockScreenLiveActivityLifecycleTests.swift -o "$overlay_test_output/check"
"$overlay_test_output/check"
