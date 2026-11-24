#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[1])
caps = Path("Anchor/Managers/Input/CapsLockManager.swift").read_text()
caps = caps.replace("import Defaults\n", "").replace("NSEvent", "FixtureEvent")
(output / "CapsLockManager.swift").write_text(caps)

battery = Path("Anchor/Managers/Battery/BatteryHistoryManager.swift").read_text()
actions = battery[battery.index("    private func start()"):battery.index("    private func record(")]
(output / "BatteryMethods.swift").write_text("import Foundation\nextension BatteryFixture {\n" + actions.replace("private func", "func") + "}\n")

fullscreen = Path("Anchor/Managers/System/FullscreenMediaDetection.swift").read_text()
actions = fullscreen[fullscreen.index("    private func scheduleScan("):fullscreen.index("    private func updateFullScreenStatus()")]
actions = actions.replace("private func", "func").replace("DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)", "enqueue(work)")
(output / "FullscreenMethods.swift").write_text("import Foundation\nextension FullscreenFixture {\n" + actions + "}\n")
PY
xcrun swiftc -swift-version 5 "$output"/{CapsLockManager,BatteryMethods,FullscreenMethods}.swift tests/HostObservationDisableLifecycleTests.swift -o "$output/check"
"$output/check"
