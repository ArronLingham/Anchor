#!/bin/bash
# Pins the settings search index against the panes it claims to index.
#
# `settingsSearchIndex` in SettingsView.swift is a hand-written array, and it
# had drifted badly: 317 rows across the panes carry a
# `.settingsHighlight(id: highlightID("Title"))` and only 217 were listed, so
# 121 settings — 38% of them — could not be found by searching for their own
# name. Nothing failed; the row simply never appeared in results.
#
# Two directions, both real defects:
#   MISSING — a row exists in a pane but has no search entry. Unfindable.
#   DEAD    — a search entry names a row that no longer exists anywhere in its
#             pane, so choosing that result scrolls to nothing.
#
# The DEAD check deliberately looks for the title anywhere in the pane source,
# not only on a `.settingsHighlight`. A row that exists but has not been given a
# highlight id still switches to the right tab, which is a lesser problem than a
# result pointing at a row that was deleted.
set -uo pipefail
cd "$(dirname "$0")/.."

scan() {  # $1 = settings directory
python3 - "$1" <<'PY'
import re, glob, os, sys, json
root = sys.argv[1]
tab_of, pane_of = {}, {}
for p in glob.glob(os.path.join(root, "*.swift")):
    src = open(p).read()
    m = re.search(r'func highlightID\(_ \w+: String\) -> String \{\s*SettingsTab\.(\w+)\.highlightID', src)
    if m:
        tab_of[p] = m.group(1)
        pane_of.setdefault(m.group(1), []).append(p)

rows = set()
for p, tab in tab_of.items():
    for t in re.findall(r'settingsHighlight\(id: highlightID\("([^"]+)"\)\)', open(p).read()):
        rows.add((tab, t))

shell = open(os.path.join(root, "SettingsView.swift")).read()
entries = set()
for m in re.finditer(r'SettingsSearchEntry\(tab: \.(\w+), title: "([^"]+)"', shell):
    entries.add((m.group(1), m.group(2)))

missing = sorted(rows - entries)
# Search every pane source, not just the one this tab's highlightID helper
# lives in: several files hold more than one View struct (SettingsHUD.swift
# carries both the HUD and Devices panes), so a per-tab file map reports rows
# that plainly exist as missing.
# ...but EXCLUDE SettingsView.swift, which holds the index itself — including
# it makes every entry match its own text and the check vacuous.
all_src = "".join(open(q).read() for q in glob.glob(os.path.join(root, "*.swift"))
                  if os.path.basename(q) != "SettingsView.swift")
dead = [(tab, title) for tab, title in sorted(entries - rows) if title not in all_src]

print(json.dumps({"rows": len(rows), "entries": len(entries),
                  "missing": missing, "dead": dead}))
PY
}

pass=0; fail=0
out=$(scan "Anchor/Components/Settings")
rows=$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['rows'])")
ents=$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['entries'])")
nmiss=$(echo "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['missing']))")
ndead=$(echo "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['dead']))")

# 1. the scan must be seeing a real repo
if [ "$rows" -ge 300 ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "  FAIL only $rows highlighted rows found — the regex has drifted"; fi

# 2. every row is searchable
if [ "$nmiss" -eq 0 ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "  FAIL $nmiss rows have no search entry and cannot be found:"
  echo "$out" | python3 -c "
import json,sys
for t,n in json.load(sys.stdin)['missing'][:15]: print(f'        {t}: {n}')" ; fi

# 3. no search entry points at a row that was deleted
if [ "$ndead" -eq 0 ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "  FAIL $ndead search entries name a row that no longer exists:"
  echo "$out" | python3 -c "
import json,sys
for t,n in json.load(sys.stdin)['dead'][:15]: print(f'        {t}: {n}')" ; fi

# 4. NEGATIVE CONTROL — delete one entry from a copy and assert MISSING notices.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp Anchor/Components/Settings/*.swift "$tmp"/
python3 - "$tmp" <<'PY2'
import os, sys, re
p = os.path.join(sys.argv[1], "SettingsView.swift")
s = open(p).read()
m = re.search(r'^ *SettingsSearchEntry\(tab: \.\w+, title: "[^"]+".*\n', s, re.M)
open(p, "w").write(s[:m.start()] + s[m.end():])
PY2
ctrl=$(scan "$tmp" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['missing']))")
if [ "$ctrl" -ge 1 ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "  FAIL negative control: removing a search entry did not register as missing"; fi

# 5. NEGATIVE CONTROL for the DEAD direction — point an entry at a row that
#    does not exist and assert the scan says so. Without this the check went
#    green while being unable to fail (it was matching entries against the file
#    that contains them).
rm -rf "$tmp"; mkdir -p "$tmp"; cp Anchor/Components/Settings/*.swift "$tmp"/
python3 - "$tmp" <<'PY3'
import os, sys, re
p = os.path.join(sys.argv[1], "SettingsView.swift")
s = open(p).read()
m = re.search(r'SettingsSearchEntry\(tab: \.(\w+), title: "([^"]+)"', s)
s = s.replace(f'title: "{m.group(2)}"', 'title: "A Row That Was Deleted Long Ago"', 1)
open(p, "w").write(s)
PY3
ctrl2=$(scan "$tmp" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['dead']))")
if [ "$ctrl2" -ge 1 ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "  FAIL negative control: an entry naming a non-existent row was not reported dead"; fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "$pass/$total passed ($rows rows, $ents entries)"; exit 0; fi
echo "$pass passed, $fail failed"; exit 1
