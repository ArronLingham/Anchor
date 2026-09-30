#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
python3 - "$WORK/TodoItem.swift" <<'PY'
import sys
s = open('Anchor/Models/TodoItem.swift').read().replace('import Defaults\n', '').replace(', Defaults.Serializable', '')
open(sys.argv[1], 'w').write(s)
PY
swiftc -O "$WORK/TodoItem.swift" Anchor/Managers/Productivity/TodoFileStore.swift \
  Anchor/Managers/Productivity/TodoSyncMerge.swift Anchor/Managers/Launcher/LauncherGridLayout.swift \
  tests/TodoStorageTests.swift -o "$WORK/tests"
"$WORK/tests"
