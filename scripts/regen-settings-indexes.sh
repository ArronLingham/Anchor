#!/bin/bash
# Regenerates the two hand-maintained settings indexes from the panes themselves.
#
#   SettingsSectionIndex.swift  — the sidebar's per-pane section list
#   settingsSearchIndex         — appends an entry for any row that has none
#
# Both drift the moment a pane grows a row, and both are pinned by harnesses, so
# this is the thing to run after adding settings rather than hand-patching two
# lists. Existing search entries are never rewritten: their keywords are
# hand-written and better than anything generated.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import re, glob, os

SETTINGS = "Anchor/Components/Settings"
tab_of = {}
for p in glob.glob(os.path.join(SETTINGS, "*.swift")):
    src = open(p).read()
    m = re.search(r'func highlightID\(_ \w+: String\) -> String \{\s*SettingsTab\.(\w+)\.highlightID', src)
    if m: tab_of[p] = m.group(1)

rows, sections = set(), {}
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
        lst = sections.setdefault(tab, [])
        if hm.group(1) not in [t for t, _ in lst]:
            lst.append((hm.group(1), rm.group(1)))

# ---- section index ----
idx = "Anchor/Components/Settings/SettingsSectionIndex.swift"
src = open(idx).read()
head = src[:src.index("    static let sections: [SettingsTab: [Section]] = [")]
tail = src[src.index("    ]\n\n    static func sections(for tab:"):]
lines = []
for tab in sorted(sections):
    items = ", ".join(f'.init(title: "{t}", anchor: "{a}")' for t, a in sections[tab])
    lines.append(f"        .{tab}: [{items}],")
open(idx, "w").write(head + "    static let sections: [SettingsTab: [Section]] = [\n"
                     + "\n".join(lines) + "\n" + tail)
print(f"section index: {sum(len(v) for v in sections.values())} sections across {len(sections)} tabs")

# ---- search entries for rows that have none ----
shell_path = os.path.join(SETTINGS, "SettingsView.swift")
shell = open(shell_path).read()
have = {(m.group(1), m.group(2)) for m in
        re.finditer(r'SettingsSearchEntry\(tab: \.(\w+), title: "([^"]+)"', shell)}
missing = sorted(rows - have)
if not missing:
    print("search index: already complete")
else:
    STOP = {"the","a","an","of","to","in","on","for","and","or","is","as","with","when",
            "this","that","it","at","by","be","from","use","show","enable"}
    def kws(tab, title):
        words = [w.lower().strip(",.—-()") for w in re.split(r'[\s/]+', title)]
        words = [w for w in words if w and w not in STOP and len(w) > 2]
        ks = list(dict.fromkeys(words))[:5]
        tw = re.sub(r'(?<!^)(?=[A-Z])', ' ', tab).lower()
        if tw not in ks: ks.append(tw)
        return ks
    gen = []
    for tab, title in missing:
        esc = title.replace('\\', '\\\\').replace('"', '\\"')
        k = ", ".join(f'"{x}"' for x in kws(tab, title))
        gen.append(f'            SettingsSearchEntry(tab: .{tab}, title: "{esc}", keywords: [{k}], '
                   f'highlightID: SettingsTab.{tab}.highlightID(for: "{esc}")),')
    i = shell.index("    private var settingsSearchIndex: [SettingsSearchEntry] {")
    j = shell.index("\n        ]\n", i)
    shell = shell[:j] + "\n" + "\n".join(gen) + shell[j:]
    open(shell_path, "w").write(shell)
    print(f"search index: added {len(missing)} entries")
PY
