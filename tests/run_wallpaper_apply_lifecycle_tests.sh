#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/ApplyMethods.swift" <<'PY'
from pathlib import Path
import sys

root = Path("Packages/AnchorUtilities/Sources/AnchorUtilities/Services/Wallpaper")
service = (root / "WallpaperService.swift").read_text()
store = (root / "WallpaperStore.swift").read_text()
apply = service[service.index("    func apply(_ entry:"):service.index("    // iCloud Drive placeholder")]
cancel = service[service.index("    private func cancelApply()"):service.index("    private func targetScreens()")]
commit = store[store.index("    private static func commitPreparedIndex("):store.index("    // first pre-feature copy")]
methods = (apply + cancel).replace("private func", "func")
Path(sys.argv[1]).write_text("import Foundation\nextension ApplyFixture {\n" + methods + "}\n"
                            "extension WallpaperStore {\n" + commit.replace("private static", "static") + "}\n")
PY
xcrun swiftc -swift-version 5 "$output/ApplyMethods.swift" tests/WallpaperApplyLifecycleTests.swift -o "$output/check"
"$output/check"
