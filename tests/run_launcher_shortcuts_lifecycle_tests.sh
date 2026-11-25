#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
sed '/^import Defaults$/d' Anchor/Managers/Launcher/ShortcutsManager.swift > "$output/ShortcutsManager.swift"
cat > "$output/fixture-shortcuts" <<'FIXTURE'
#!/bin/sh
directory=${0%/*}
case "$1" in
    list)
        if [ -f "$directory/fast" ]; then
            printf '%s\n' 'Fixture Shortcut'
            exit 0
        fi
        printf '%s\n' "$$" > "$directory/listing-pid.tmp"
        mv "$directory/listing-pid.tmp" "$directory/listing-pid"
        exec /bin/sleep 10
        ;;
    run)
        printf '%s\n' "$2" > "$directory/ran.tmp"
        mv "$directory/ran.tmp" "$directory/ran"
        ;;
esac
FIXTURE
chmod +x "$output/fixture-shortcuts"
xcrun swiftc -swift-version 5 "$output/ShortcutsManager.swift" tests/LauncherAppleShortcutsLifecycleTests.swift -o "$output/check"
"$output/check" "$output/fixture-shortcuts"
