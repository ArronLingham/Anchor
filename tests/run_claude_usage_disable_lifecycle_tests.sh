#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/ResumeLease.swift" <<'PY'
from pathlib import Path
import sys

source = Path("Anchor/Managers/ClaudeUsage/ClaudeUsageManager.swift").read_text()
start = source.index("    private final class ResumeLease")
end = source.index("\n    private var activeResumeLease", start)
lease = source[start:end].replace("    private final class", "final class", 1)
Path(sys.argv[1]).write_text("import Foundation\n" + lease)

required = [
    "Defaults.publisher(.claudeUsageAutoResume)",
    "retireActiveResume()",
    "guard Defaults[.claudeUsageWatchEnabled] else { return }",
    "guard generation == resetGeneration else { return }",
    "activeResumeLease === lease, lease.isActive",
    "lease.performIfActive {",
]
for needle in required:
    if needle not in source:
        raise SystemExit(f"missing disablement integration: {needle}")
PY
xcrun swiftc -swift-version 5 "$output/ResumeLease.swift" tests/ClaudeUsageDisableLifecycleTests.swift -o "$output/check"
"$output/check"
