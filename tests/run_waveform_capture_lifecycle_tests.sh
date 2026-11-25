#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output" <<'PY'
from pathlib import Path
import sys

source = Path("Anchor/Audio/AudioTap.swift").read_text()
lifecycle = source[source.index("    /// Registers a visible consumer."):source.index("    private func startCaptureSync")]
shutdown = source[source.index("    func stopCapture()"):source.index("    private func stopCaptureSync")]
Path(sys.argv[1], "WaveformLifecycleMethods.swift").write_text(
    "import Foundation\n\nextension WaveformFixture {\n" + (lifecycle + shutdown).replace("private ", "") + "}\n"
)
PY
xcrun swiftc -swift-version 5 "$output/WaveformLifecycleMethods.swift" tests/WaveformCaptureLifecycleTests.swift -o "$output/check"
"$output/check"
