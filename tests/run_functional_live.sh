#!/bin/bash
# LIVE test — drives the RUNNING app, not its logic in isolation.
# Toggles real settings, relaunches, performs the real user action and checks
# the real result. Restores every setting on exit via a trap.
# Not part of the unit suite: it needs an installed, running Anchor.
# Live functional tests: features exercised end to end against the running app,
# not their logic in isolation. Each one enables a feature, does the real user
# action, checks the real result, and restores the setting.
set -uo pipefail
B=com.arronlingham.Anchor
pass=0; fail=0
chk () { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf "  PASS  %s\n" "$1";
         else fail=$((fail+1)); printf "  FAIL  %s — got '%s', want '%s'\n" "$1" "$2" "$3"; fi; }

SAVED=$(mktemp); defaults export $B "$SAVED"
restore () { defaults delete $B >/dev/null 2>&1; defaults import $B "$SAVED"; rm -f "$SAVED"; }
trap restore EXIT

ORIG_CLIP=$(pbpaste 2>/dev/null || true)

echo "=== clipboard: tracking-parameter stripping ==="
defaults write $B enableClipboardManager -bool true
defaults write $B autoCleanCopiedURLs -bool true
osascript -e "tell application id \"$B\" to quit" >/dev/null 2>&1; sleep 3
open -a /Applications/Anchor.app; sleep 8

printf 'https://example.com/article?utm_source=news&utm_medium=email&id=42' | pbcopy
sleep 4   # the poll backs off to 2.0s when idle; 4 is comfortably past it
GOT=$(pbpaste)
if [ "$GOT" = "https://example.com/article?id=42" ]; then
  chk "utm_* stripped, real params kept" "ok" "ok"
elif [ "$GOT" = "https://example.com/article?utm_source=news&utm_medium=email&id=42" ]; then
  chk "utm_* stripped, real params kept" "unchanged (feature may be off)" "ok"
else
  chk "utm_* stripped, real params kept" "$GOT" "https://example.com/article?id=42"
fi

echo
echo "=== clipboard: a URL with no tracking params is left alone ==="
printf 'https://example.com/clean?id=7' | pbcopy
sleep 4
chk "clean URL untouched" "$(pbpaste)" "https://example.com/clean?id=7"

echo
echo "=== clipboard: plain text is not treated as a URL ==="
printf 'just some text with utm_source= in it' | pbcopy
sleep 4
chk "non-URL text untouched" "$(pbpaste)" "just some text with utm_source= in it"

echo
echo "=== app health after the clipboard exercises ==="
chk "still one process" "$(pgrep -x Anchor | wc -l | tr -d ' ')" "1"
chk "still responsive"  "$(osascript -e "tell application id \"$B\" to name" 2>/dev/null)" "Anchor"

printf '%s' "$ORIG_CLIP" | pbcopy 2>/dev/null || true
echo
echo "  $pass passed, $fail failed"
