#!/bin/bash
# Pins SettingsSectionIndex against the panes it describes.
#
# The sidebar lists each pane's own sections, because a pane is one long Form
# and its sections are the only structure inside it — without this the sidebar
# takes you to "Controls" but not to the "Step size" part of it.
#
# Section headers carry no highlight id of their own, so each entry points at
# the FIRST row in its section. Two ways that can rot, both checked:
#   STALE ANCHOR — the anchor row no longer exists, so choosing the section
#                  scrolls to nothing.
#   MISSING      — a pane grew a section that the sidebar does not list.
set -uo pipefail
cd "$(dirname "$0")/.."

scan() {  # $1 = settings dir
python3 - "$1" <<'PY'
import re, glob, os, sys, json
root = sys.argv[1]
tab_of = {}
for p in glob.glob(os.path.join(root, "*.swift")):
    src = open(p).read()
    m = re.search(r'func highlightID\(_ \w+: String\) -> String \{\s*SettingsTab\.(\w+)\.highlightID', src)
    if m: tab_of[p] = m.group(1)

actual, rows = {}, set()
for p, tab in sorted(tab_of.items()):
    src = open(p).read()
    for t in re.findall(r'settingsHighlight\(id: highlightID\("([^"]+)"\)\)', src):
        rows.add((tab, t))
    for m in re.finditer(r'\bSection\s*\{', src):
        start = m.end() - 1
        depth, k = 0, start
        while k < len(src):
            if src[k] == '{': depth += 1
            elif src[k] == '}':
                depth -= 1
                if depth == 0: break
            k += 1
        body, tail = src[start:k], src[k:k+260]
        hm = re.match(r'\}\s*header:\s*\{\s*(?:.*?)Text\("([^"]+)"\)', tail, re.S)
        if not hm: continue
        rm = re.search(r'settingsHighlight\(id: highlightID\("([^"]+)"\)\)', body)
        if not rm: continue
        lst = actual.setdefault(tab, [])
        if hm.group(1) not in [t for t, _ in lst]:
            lst.append((hm.group(1), rm.group(1)))

idx_path = os.path.join(root, "SettingsSectionIndex.swift")
idx_src = open(idx_path).read() if os.path.exists(idx_path) else ""
declared = {}
for m in re.finditer(r'\.(\w+): \[(.*?)\],?\n', idx_src):
    tab, blob = m.group(1), m.group(2)
    declared[tab] = re.findall(r'\.init\(title: "([^"]+)", anchor: "([^"]+)"\)', blob)

stale = [(t, title, a) for t, items in declared.items() for title, a in items
         if (t, a) not in rows]
missing = [(t, title) for t, items in actual.items() for title, _ in items
           if title not in [d for d, _ in declared.get(t, [])]]
print(json.dumps({"declared": sum(len(v) for v in declared.values()),
                  "actual": sum(len(v) for v in actual.values()),
                  "stale": stale, "missing": missing}))
PY
}

pass=0; fail=0
out=$(scan "Anchor/Components/Settings")
dec=$(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['declared'])")
nstale=$(echo "$out" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['stale']))")
nmiss=$(echo "$out" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['missing']))")

if [ "$dec" -ge 80 ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "  FAIL only $dec sections declared — the index looks truncated"; fi

if [ "$nstale" -eq 0 ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "  FAIL $nstale section(s) anchored to a row that no longer exists:"
  echo "$out" | python3 -c "
import json,sys
for t,ti,a in json.load(sys.stdin)['stale'][:10]: print(f'        {t} / {ti} -> {a}')"; fi

if [ "$nmiss" -eq 0 ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "  FAIL $nmiss section(s) exist in a pane but are not in the sidebar index:"
  echo "$out" | python3 -c "
import json,sys
for t,ti in json.load(sys.stdin)['missing'][:10]: print(f'        {t} / {ti}')"; fi

# NEGATIVE CONTROL — repoint one anchor at a row that does not exist.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp Anchor/Components/Settings/*.swift "$tmp"/
python3 - "$tmp" <<'PY2'
import os, sys, re
p = os.path.join(sys.argv[1], "SettingsSectionIndex.swift")
s = open(p).read()
m = re.search(r'anchor: "([^"]+)"', s)
open(p, "w").write(s.replace(f'anchor: "{m.group(1)}"', 'anchor: "A Row Deleted Long Ago"', 1))
PY2
ctrl=$(scan "$tmp" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['stale']))")
if [ "$ctrl" -ge 1 ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "  FAIL negative control: a bogus anchor was not reported stale"; fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "$pass/$total passed ($dec sections indexed)"; exit 0; fi
echo "$pass passed, $fail failed"; exit 1
