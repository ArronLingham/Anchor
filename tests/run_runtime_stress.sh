#!/bin/bash
# LIVE stress — hostile Defaults values against the RUNNING app.
# Writes extreme integers, hostile strings and rapid toggles, then checks the
# app is alive, responsive and crash-free. Restores nothing: run it inside a
# defaults export/import, as the campaign did.
# Runtime stress: does the live app survive hostile Defaults values and rapid
# toggling? Unit tests cover the logic; this covers the wiring.
set -uo pipefail
B=com.arronlingham.Anchor
pid () { pgrep -x Anchor | head -1; }
alive () { [ -n "$(pid)" ] && echo yes || echo no; }
crashes () { find ~/Library/Logs/DiagnosticReports -name "Anchor*" -mmin -"$1" 2>/dev/null | wc -l | tr -d ' '; }

echo "=== baseline ==="
echo "  alive: $(alive)  pid: $(pid)  rss: $(ps -o rss= -p "$(pid)" | awk '{printf "%.1f MB",$1/1024}')"

echo
echo "=== 1. hostile integer values on every Int key ==="
INTKEYS=$(grep -oE 'static let [a-zA-Z0-9_]+ = Key<Int>' /Users/arronlingham/Anchor/Anchor/Models/Constants.swift | awk '{print $3}')
n=0
for k in $INTKEYS; do
  for v in -2147483648 -1 0 2147483647; do
    defaults write $B "$k" -int $v 2>/dev/null && n=$((n+1))
  done
done
echo "  wrote $n extreme integer values across $(echo "$INTKEYS" | wc -l | tr -d ' ') Int keys"
sleep 5
echo "  alive after: $(alive)   new crashes: $(crashes 2)"

echo
echo "=== 2. hostile string values on every String key ==="
STRKEYS=$(grep -oE 'static let [a-zA-Z0-9_]+ = Key<String>' /Users/arronlingham/Anchor/Anchor/Models/Constants.swift | awk '{print $3}')
n=0
for k in $STRKEYS; do
  for v in "" "   " "🎧💥" "$(printf 'A%.0s' {1..500})" "../../etc/passwd" "'; DROP TABLE --"; do
    defaults write $B "$k" -string "$v" 2>/dev/null && n=$((n+1))
  done
done
echo "  wrote $n hostile strings across $(echo "$STRKEYS" | wc -l | tr -d ' ') String keys"
echo "  (includes empty, whitespace, emoji, 500 chars, path traversal, SQL-ish)"
sleep 5
echo "  alive after: $(alive)   new crashes: $(crashes 2)"

echo
echo "=== 3. rapid toggle storm — 200 flips across 10 features ==="
FEAT="enableCameraMirror enableGeminiAssistant enableKeyDebounce enableSnapZones enableShelf
      enableSystemStats enableTodoFeature menuBarShowCPU enableDiskImageInstaller enableCleanup"
for i in $(seq 1 20); do
  for k in $FEAT; do
    defaults write $B "$k" -bool $([ $((i % 2)) -eq 0 ] && echo true || echo false) 2>/dev/null
  done
done
echo "  200 toggles issued"
sleep 6
echo "  alive after: $(alive)   new crashes: $(crashes 2)"
echo "  rss: $(ps -o rss= -p "$(pid)" 2>/dev/null | awk '{printf "%.1f MB",$1/1024}')"

echo
echo "=== 4. type confusion — write a string where an Int is expected ==="
for k in $(echo "$INTKEYS" | head -8); do
  defaults write $B "$k" -string "not a number" 2>/dev/null
done
sleep 5
echo "  alive after: $(alive)   new crashes: $(crashes 2)"

echo
echo "=== 5. still responsive? ==="
echo -n "  AppleScript: "; osascript -e "tell application id \"$B\" to name" 2>&1 | head -1
echo "  OSDUIHelper: $(ps -o state= -p "$(pgrep -x OSDUIHelper)" 2>/dev/null | tr -d ' ')"
echo
echo "=== total new crash reports across the whole run: $(crashes 5) ==="
