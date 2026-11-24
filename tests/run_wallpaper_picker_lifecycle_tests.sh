#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/PickerMethods.swift" <<'PY'
from pathlib import Path
import sys

source = Path("Packages/AnchorUtilities/Sources/AnchorUtilities/Services/Wallpaper/WallpaperService.swift").read_text()
methods = source[source.index("    private func present(_ panel:"):source.index("    private func remember(urls:")]
methods = methods.replace("private func", "func").replace("NSOpenPanel", "TestPanel")
Path(sys.argv[1]).write_text("import Foundation\nextension PickerFixture {\n" + methods + "}\n")
PY
xcrun swiftc -swift-version 5 "$output/PickerMethods.swift" tests/WallpaperPickerLifecycleTests.swift -o "$output/check"
"$output/check"
