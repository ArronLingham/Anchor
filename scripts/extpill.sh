#!/bin/bash
# Structural probe for the pill on displays without a physical notch.
#
# Reports what the WINDOW SERVER actually has — not what the code intends and
# not what a screenshot would show, because Screen Recording is not granted to
# the shell here. Answers, per external display: does an opaque Anchor panel
# exist at its top edge, is anything at a normal window level covering it, and
# is it centred?
#
# This exists because two sessions in this project recorded "needs a monitor,
# cannot verify" while a second display was attached the whole time. Run the
# probe instead of reasoning about window levels.
#
#   scripts/extpill.sh
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
swiftc -O scripts/extpill.swift -o "$WORK/extpill" 2>&1 | grep -E "error" || true
"$WORK/extpill"
