#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/ArtworkMethods.swift" <<'PY'
from pathlib import Path
import sys

source = Path("Anchor/Managers/Media/MusicManager.swift").read_text()
types = source[source.index("    enum ArtworkConsumer"):source.index("    enum SkipDirection")]
methods = source[source.index("    static var lockScreenArtworkEnabled:"):source.index("    func toggleLyrics()")]
body = (types + methods).replace("private ", "")
Path(sys.argv[1]).write_text("import Foundation\nextension ArtworkFixture {\n" + body + "}\n")
PY
xcrun swiftc -swift-version 5 "$output/ArtworkMethods.swift" tests/AnimatedArtworkDemandTests.swift -o "$output/check"
"$output/check"
