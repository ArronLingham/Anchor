#!/bin/bash
# Pins the "settings dropdowns don't visually update" bug class.
#
# A control bound to `Binding(get: { Defaults[.key] }, set: { Defaults[.key] = $0 })`
# reads the value IMPERATIVELY. SwiftUI records no dependency on it, so writing
# the value never invalidates the view — the write lands in Defaults but the
# Picker goes on rendering its previous selection. It looks like the setting is
# being ignored; it is not, only the redraw is missing.
#
# Four panes shipped this way, including the "Open and close" animation picker
# the user reported. The fix is `@Default(.key) private var x` and a binding
# that returns `$x`: @Default subscribes to the key and republishes.
#
# THE RULE: if a Settings file reads Defaults[.key] inside a Binding, that same
# file must also declare @Default(.key) — so something in the view is genuinely
# subscribed. Twenty-one other bindings in these panes already pass, because
# they transform a value that is itself @Default-backed.
#
# This is not a style check. Every violation is a control that silently fails
# to update.
set -uo pipefail
cd "$(dirname "$0")/.."

run_scan() {   # $1 = directory to scan
python3 - "$1" <<'PY'
import re, glob, sys, os
root = sys.argv[1]
violations, bindings = [], 0
for path in sorted(glob.glob(os.path.join(root, "*.swift"))):
    src = open(path).read()
    tracked = set(re.findall(r'@Default\(\.(\w+)\)', src))
    for m in re.finditer(r'Binding\((?:[^()]|\([^()]*\))*\)', src, re.S):
        body = m.group(0)
        if 'get:' not in body:
            continue
        bindings += 1
        for key in sorted(set(re.findall(r'Defaults\[\.(\w+)\]', body))):
            if key not in tracked:
                line = src[:m.start()].count('\n') + 1
                violations.append(f"{os.path.basename(path)}:{line} reads Defaults[.{key}] in a Binding, but the file declares no @Default(.{key})")
    # Same bug, second shape: `if Defaults[.key] { ...sub-options... }`. The
    # toggle writes the key, the parent never re-renders, and the sub-options
    # do not appear until the pane is left and re-entered. Fourteen of these
    # shipped alongside the twelve bindings.
    for m in re.finditer(r'\bif +Defaults\[\.(\w+)\]', src):
        bindings += 1
        key = m.group(1)
        if key not in tracked:
            line = src[:m.start()].count('\n') + 1
            violations.append(f"{os.path.basename(path)}:{line} gates a section on Defaults[.{key}], but the file declares no @Default(.{key})")
print(f"BINDINGS {bindings}")
for v in violations:
    print(f"VIOLATION {v}")
PY
}

pass=0; fail=0
out=$(run_scan "Anchor/Components/Settings")
count=$(echo "$out" | awk '/^BINDINGS/{print $2}')
viol=$(echo "$out" | grep '^VIOLATION ' | sed 's/^VIOLATION //')

# 1. the scan must actually be looking at something
if [ "${count:-0}" -ge 20 ]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "  FAIL scan found only ${count:-0} tracked reads — the regex has drifted, not a clean repo"
fi

# 2. no pane may read Defaults inside a Binding without subscribing to that key
if [ -z "$viol" ]; then
  pass=$((pass+1))
else
  n=$(echo "$viol" | wc -l | tr -d ' ')
  fail=$((fail+1))
  echo "  FAIL $n untracked Defaults binding(s) — these controls will not redraw:"
  echo "$viol" | sed 's/^/        /'
fi

# 3. NEGATIVE CONTROL — reintroduce the exact pattern that shipped, in a temp
#    copy, and assert the scan goes red. A guard no control can break is not a
#    guard; this repo has shipped two of those already.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp Anchor/Components/Settings/*.swift "$tmp"/
python3 - "$tmp" <<'PY'
import re, os, sys
p = os.path.join(sys.argv[1], "SettingsAppearance.swift")
s = open(p).read()
s = s.replace("    @Default(.notchAnimationProfile) private var animationProfile\n", "")
s = s.replace(
    "    private var animationProfileBinding: Binding<NotchAnimationProfile> { $animationProfile }",
    "    private var animationProfileBinding: Binding<NotchAnimationProfile> {\n"
    "        Binding(\n            get: { Defaults[.notchAnimationProfile] },\n"
    "            set: { Defaults[.notchAnimationProfile] = $0 }\n        )\n    }")
open(p, "w").write(s)
PY
ctrl=$(run_scan "$tmp" | grep -c '^VIOLATION ' || true)
if [ "$ctrl" -ge 1 ]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "  FAIL negative control (binding): reintroducing the shipped bug did NOT trip the scan"
fi

# 4. NEGATIVE CONTROL for the conditional shape — drop one @Default that only a
#    `if Defaults[.key]` gate depends on, and assert the scan notices.
rm -rf "$tmp"; mkdir -p "$tmp"; cp Anchor/Components/Settings/*.swift "$tmp"/
python3 - "$tmp" <<'PY2'
import os, sys, re
p = os.path.join(sys.argv[1], "SettingsMedia.swift")
s = open(p).read()
s = s.replace("    @Default(.enableCameraMirror) private var enableCameraMirror\n", "")
s = re.sub(r'\bif enableCameraMirror\b', 'if Defaults[.enableCameraMirror]', s)
open(p, "w").write(s)
PY2
ctrl2=$(run_scan "$tmp" | grep -c '^VIOLATION ' || true)
if [ "$ctrl2" -ge 1 ]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "  FAIL negative control (conditional): unsubscribed section gate did NOT trip the scan"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "$pass/$total passed ($count bindings scanned)"; exit 0; fi
echo "$pass passed, $fail failed"; exit 1
