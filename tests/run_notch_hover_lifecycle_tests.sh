#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output" <<'PY'
from pathlib import Path
import sys

source = Path("Anchor/Managers/Input/NotchHoverManager.swift").read_text()
source = source.replace("import Defaults\n", "").replace("NSEvent", "FixtureEvent")
start = source.index("    private func currentDisplays()")
end = source.index("    private func publish(", start)
source = source[:start] + """
    private func currentDisplays() -> [NotchHoverGeometry.Display] {
        [.init(name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
               closedNotchSize: CGSize(width: 180, height: 35))]
    }

""" + source[end:]
output = Path(sys.argv[1])
(output / "NotchHoverManager.swift").write_text(source)

delegate = Path("Anchor/AnchorApp.swift").read_text()
start = delegate.index("    @objc func onScreenLocked")
end = delegate.index("    private func hideWindowsForLock", start)
transitions = delegate[start:end].replace("@objc ", "")
transitions = transitions.replace("DispatchQueue.main.asyncAfter(deadline: .now() + 1.0)", "afterUnlock")
(output / "IslandLockMethods.swift").write_text(
    "import Foundation\n\nextension IslandLockFixture {\n" + transitions + "}\n"
)
PY
xcrun swiftc -swift-version 5 "$output"/{NotchHoverManager,IslandLockMethods}.swift Anchor/Managers/Input/NotchHoverGeometry.swift tests/NotchHoverLifecycleTests.swift -o "$output/check"
"$output/check"
