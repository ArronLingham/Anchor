#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
sources=Packages/AnchorUtilities/Sources/AnchorUtilities/Services/MouseAcceleration
python3 - "$sources/MouseAccelerationService.swift" "$output/RecoveryMethods.swift" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
recovery = source[source.index("    private func observePendingRecovery()"):
                  source.index("    // MARK: - Device lifecycle")]
scheduling = source[source.index("    private func scheduleDeviceReapplication()"):
                    source.index("    private func startDeviceObservation()")]
methods = (recovery + scheduling).replace("private func", "func")
methods = methods.replace("DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)",
                          "enqueueRetry(after: delay, execute: work)")
Path(sys.argv[2]).write_text("import Foundation\nextension RecoveryFixture {\n" + methods + "}\n")
PY
xcrun swiftc -swift-version 5 "$output/RecoveryMethods.swift" \
    "$sources/MouseAccelerationSupport.swift" tests/MouseAccelerationRecoveryLifecycleTests.swift -o "$output/check"
"$output/check"
