#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
sed -e '/^import AnchorUtilities$/d' -e '/^import Defaults$/d' \
    Anchor/Managers/HUD/SystemHUDManager.swift > "$output/SystemHUDManager.swift"
sed -e 's/private func dispatchMuteCommand/func dispatchMuteCommand/' \
    Anchor/Managers/HUD/MediaKeyInterceptor.swift > "$output/MediaKeyInterceptor.swift"
xcrun swiftc -swift-version 5 "$output/SystemHUDManager.swift" "$output/MediaKeyInterceptor.swift" tests/HUDOwnershipTests.swift -o "$output/check"
"$output/check"

python3 - "$output" <<'PYTEST'
from pathlib import Path
import sys
source = Path("Anchor/Managers/HUD/SystemOSDManager.swift").read_text()
start = source.index("    private static func pids(named")
end = source.index("    private static func osduiHelperPID()", start)
source = source[:start] + (
    "    private static func pids(named name: String) -> [pid_t] { [12345] }\n"
    "    private static func isSystemHelper(_ pid: pid_t) -> Bool { pid == 12345 }\n"
) + source[end:]
source = source.replace("kill(pid, SIGSTOP)", "OSDSignalFixture.send(pid, SIGSTOP)")
source = source.replace("kill(pid, signal)", "OSDSignalFixture.send(pid, signal)")
source += """
enum OSDSignalFixture {
    static var calls: [Int32] = []
    static func send(_ pid: pid_t, _ signal: Int32) -> Int32 {
        precondition(pid == 12345)
        calls.append(signal)
        return 0
    }
}

enum SystemActivityGate {
    static let shared = (shouldSuspendBackgroundWork: false, unused: false)
}

extension SystemOSDManager {
    static func verifyRetiredSignal() {
        let generation = suppressionState.withLock { state in
            state.active = true
            state.transitionGeneration += 1
            return state.transitionGeneration
        }
        suspendIfCurrent(12345, generation: generation)
        enableSystemHUD()
        suspendIfCurrent(12345, generation: generation)
        precondition(OSDSignalFixture.calls == [SIGSTOP, SIGCONT])
        print("Native HUD release rejects stale helper suspension")
    }
}
"""
(Path(sys.argv[1]) / "main.swift").write_text(source + "\nSystemOSDManager.verifyRetiredSignal()\n")
PYTEST
xcrun swiftc -swift-version 5 "$output/main.swift" -o "$output/signal-check"
"$output/signal-check"
