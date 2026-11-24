#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/WatchMethods.swift" <<'PY'
from pathlib import Path
import sys

source = Path("Anchor/Managers/System/NotificationMirrorManager.swift").read_text()
methods = source[source.index("    private func acceptsWatchEvent("):source.index("    private func stop()")]
methods = methods.replace("private func", "func")
methods = methods.replace("DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: rearm)", "enqueue(rearm)")
Path(sys.argv[1]).write_text("import Foundation\nextension WatchFixture {\n" + methods + "}\n")
PY
xcrun swiftc -swift-version 5 "$output/WatchMethods.swift" tests/NotificationMirrorDisableLifecycleTests.swift -o "$output/check"
"$output/check"
