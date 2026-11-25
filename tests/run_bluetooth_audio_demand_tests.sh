#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output" <<'PY'
from pathlib import Path
import sys

source = Path("Anchor/Managers/Audio/BluetoothAudioManager.swift").read_text()
demand = source[source.index("    private var needsDeviceObservation:"):source.index("    private var cancellables")]
device_lifecycle = source[source.index("    @MainActor\n    func setLockScreenBatteryVisible"):source.index("    /// Watches private")]
polling = source[source.index("    // Distributed notifications are the primary path."):source.index("    /// Checks for device connection/disconnection changes")]
members = (demand + device_lifecycle + polling).replace("private ", "")
Path(sys.argv[1], "BluetoothDemandMethods.swift").write_text(
    "import Combine\nimport Foundation\n\nextension BluetoothFixture {\n" + members + "}\n"
)
controllers = Path("Anchor/Managers/Audio/SystemMediaControllers.swift").read_text()
suppression = controllers[controllers.index("final class HUDSuppressionCoordinator"):controllers.index("final class SystemVolumeController")]
Path(sys.argv[1], "HUDSuppressionCoordinator.swift").write_text("import Foundation\n" + suppression)
PY
xcrun swiftc -swift-version 5 "$output"/{BluetoothDemandMethods,HUDSuppressionCoordinator}.swift tests/BluetoothAudioDemandTests.swift -o "$output/check"
"$output/check"
