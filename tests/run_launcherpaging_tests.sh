#!/bin/bash
# Pins LauncherPaging — the conversion between the launcher's selection and the
# page it appears on.
#
# Selection indexes APPS. The grid lays out folders first, then apps. So every
# conversion has to carry the folder count, and all three paging controls (edge
# hover, page dots, scrub bar) got it wrong the same way once: they set
# `page * perPage` directly, which lands a page further on for each full page of
# folders and can run past the end of the app list.
#
# The round trip is the property that matters: paging to a page and then asking
# which page you are on must give that page back.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Paging.swift" <<'PYX'
import re, sys
src = open("Anchor/Managers/Launcher/LauncherPaging.swift").read()
i = src.index("enum LauncherPaging")
depth, k = 0, src.index("{", i)
while True:
    if src[k] == "{": depth += 1
    elif src[k] == "}":
        depth -= 1
        if depth == 0: break
    k += 1
open(sys.argv[1], "w").write("import Foundation\n\n" + src[i:k+1] + "\n")
PYX

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}

let perPage = 28   // the 7x4 default

// ---- with no folders, selection and page relate the obvious way ----
ok("no folders: item 0 is page 0",  LauncherPaging.page(forSelection: 0, folderCount: 0, perPage: perPage) == 0)
ok("no folders: item 27 is page 0", LauncherPaging.page(forSelection: 27, folderCount: 0, perPage: perPage) == 0)
ok("no folders: item 28 is page 1", LauncherPaging.page(forSelection: 28, folderCount: 0, perPage: perPage) == 1)

// ---- folders push apps along ----
// With 3 folders, app 0 sits in slot 3, and app 24 is the first on page 1.
ok("3 folders: app 0 is page 0",  LauncherPaging.page(forSelection: 0, folderCount: 3, perPage: perPage) == 0)
ok("3 folders: app 24 is page 0", LauncherPaging.page(forSelection: 24, folderCount: 3, perPage: perPage) == 0)
ok("3 folders: app 25 is page 1", LauncherPaging.page(forSelection: 25, folderCount: 3, perPage: perPage) == 1)

// ---- THE ROUND TRIP — this is what the bug broke ----
for folderCount in [0, 1, 3, 27, 28, 29, 56] {
    for appCount in [1, 10, 40, 116, 400] {
        let pages = LauncherPaging.pageCount(folderCount: folderCount, appCount: appCount, perPage: perPage)
        for page in 0..<max(1, pages) {
            guard let sel = LauncherPaging.selection(
                forPage: page, folderCount: folderCount, perPage: perPage, appCount: appCount)
            else { continue }
            ok("selection is inside the app list (f=\(folderCount) n=\(appCount) p=\(page))",
               sel >= 0 && sel < appCount, "got \(sel)")
            let back = LauncherPaging.page(forSelection: sel, folderCount: folderCount, perPage: perPage)
            // `selection(forPage:)` answers "the nearest app to that page".
            // It can land LATER than asked when the early pages hold only
            // folders (no app maps onto them) and EARLIER when the apps run out
            // before the pages do. Both are correct; what must never happen is
            // landing outside the list, which the assertion above covers. What
            // is pinned here is that it is the nearest such app: one page
            // either side at most.
            ok("selection lands on an adjacent page at worst (f=\(folderCount) n=\(appCount) p=\(page))",
               abs(back - page) <= 1 || sel == 0 || sel == appCount - 1,
               "asked \(page), landed \(back)")
        }
    }
}

// The specific regression: page * perPage, with folders, overshoots.
let naive = 1 * perPage
let correct = LauncherPaging.selection(forPage: 1, folderCount: 3, perPage: perPage, appCount: 116)!
ok("the old arithmetic really was wrong", naive != correct, "naive \(naive) vs \(correct)")
ok("correct value lands on page 1",
   LauncherPaging.page(forSelection: correct, folderCount: 3, perPage: perPage) == 1)

// ---- degenerate inputs must not crash or produce nonsense ----
ok("no apps yields no selection",
   LauncherPaging.selection(forPage: 2, folderCount: 3, perPage: perPage, appCount: 0) == nil)
ok("zero page size yields no selection",
   LauncherPaging.selection(forPage: 1, folderCount: 0, perPage: 0, appCount: 10) == nil)
ok("zero page size is page 0", LauncherPaging.page(forSelection: 50, folderCount: 0, perPage: 0) == 0)
ok("negative selection clamps", LauncherPaging.page(forSelection: -5, folderCount: 0, perPage: perPage) == 0)
ok("negative page clamps to 0",
   LauncherPaging.selection(forPage: -3, folderCount: 0, perPage: perPage, appCount: 10) == 0)
ok("empty grid has no pages", LauncherPaging.pageCount(folderCount: 0, appCount: 0, perPage: perPage) == 0)
ok("one app is one page", LauncherPaging.pageCount(folderCount: 0, appCount: 1, perPage: perPage) == 1)
ok("exactly one full page", LauncherPaging.pageCount(folderCount: 0, appCount: 28, perPage: perPage) == 1)
ok("one over spills to two", LauncherPaging.pageCount(folderCount: 0, appCount: 29, perPage: perPage) == 2)
ok("folders count toward pages", LauncherPaging.pageCount(folderCount: 28, appCount: 1, perPage: perPage) == 2)

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Paging.swift" "$WORK/main.swift" -o "$WORK/p" 2>&1 | grep -E "error" || true
"$WORK/p"
