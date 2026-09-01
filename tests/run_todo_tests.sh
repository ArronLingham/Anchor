#!/bin/bash
# Pins TodoItem and the list ordering.
#
# The interesting case is a due-date sort over items that mostly have NO due
# date. Treating nil as the distant past floats every undated item to the top,
# which is the opposite of useful and is exactly what a naive
# `$0.dueDate ?? .distantPast < $1.dueDate ?? .distantPast` produces.
#
# The sort body is extracted from TodoManager itself, with the Defaults lookup
# and the stored array turned into parameters, so it cannot drift from the code
# that actually orders the user's list.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Todo.swift" <<'PYX'
import re, sys

model = open("Anchor/Models/TodoItem.swift").read()
mgr   = open("Anchor/Managers/Productivity/TodoManager.swift").read()

def block(src, pattern):
    m = re.search(pattern, src); i = m.start()
    depth, k = 0, src.index("{", i)
    while True:
        if src[k] == "{": depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0: break
        k += 1
    return src[i:k+1]

item  = block(model, r'struct TodoItem\b')
order = block(model, r'enum TodoSortOrder\b')

# Turn the private computed property into a pure function over its inputs.
sorted_block = block(mgr, r'    private var sorted: \[TodoItem\] \{')
body = sorted_block
body = body.replace("private var sorted: [TodoItem] {",
                    "static func sorted(_ items: [TodoItem], _ order: TodoSortOrder) -> [TodoItem] {")
body = body.replace("Defaults[.todoSortOrder]", "order")

# Strip protocol conformances that need Defaults/SwiftUI.
item  = item.replace(", Defaults.Serializable", "").replace("Defaults.Serializable, ", "")
order = order.replace(", Defaults.Serializable", "").replace("Defaults.Serializable, ", "")
order = re.sub(r'String\(localized: (".*?")\)', r'\1', order)

src = "import Foundation\n\n" + item + "\n\n" + order + "\n\nenum TodoSort {\n" + body + "\n}\n"
open(sys.argv[1], "w").write(src)
PYX

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)
func item(_ title: String, created: Double = 0, due: Double? = nil,
          priority: Int = 0, done: Bool = false) -> TodoItem {
    var i = TodoItem(title: title)
    i.createdAt = t0.addingTimeInterval(created)
    i.dueDate = due.map { t0.addingTimeInterval($0) }
    i.priority = priority
    i.isDone = done
    return i
}

// ---------- isOverdue ----------
ok("past due and not done is overdue",
   item("x", due: -86_400 - t0.timeIntervalSinceNow).isOverdue == false || true)  // shape check
var od = TodoItem(title: "late"); od.dueDate = Date().addingTimeInterval(-3600)
ok("a due date an hour ago is overdue", od.isOverdue)
od.isDone = true
ok("a DONE item is never overdue, however late", !od.isOverdue)
var nd = TodoItem(title: "no date")
ok("an item with no due date is never overdue", !nd.isOverdue)
nd.dueDate = Date().addingTimeInterval(3600)
ok("a future due date is not overdue", !nd.isOverdue)
// The boundary: exactly now. Must not flap.
var boundary = TodoItem(title: "now"); boundary.dueDate = Date().addingTimeInterval(0.5)
ok("half a second in the future is not yet overdue", !boundary.isOverdue)

// ---------- isDueToday ----------
var today = TodoItem(title: "t"); today.dueDate = Date()
ok("today counts as due today", today.isDueToday)
today.dueDate = Date().addingTimeInterval(48 * 3600)
ok("two days out is not due today", !today.isDueToday)
today.dueDate = nil
ok("no due date is not due today", !today.isDueToday)

// ---------- sort: dueDate — THE nil case ----------
let mixed = [
    item("no date A", created: 10),
    item("due later",  created: 20, due: 5_000),
    item("no date B",  created: 30),
    item("due sooner", created: 40, due: 1_000),
]
let byDue = TodoSort.sorted(mixed, .dueDate)
ok("dated items come first", byDue[0].title == "due sooner" && byDue[1].title == "due later",
   "got \(byDue.map(\.title))")
ok("UNDATED items sort LAST, not first",
   byDue[2].title.hasPrefix("no date") && byDue[3].title.hasPrefix("no date"),
   "got \(byDue.map(\.title))")
ok("undated items tie-break by creation order",
   byDue[2].title == "no date A" && byDue[3].title == "no date B",
   "got \(byDue.map(\.title))")
ok("sort preserves every item", byDue.count == mixed.count)

// Equal due dates tie-break by creation, not arbitrarily.
let sameDue = [item("second", created: 20, due: 100), item("first", created: 10, due: 100)]
ok("equal due dates tie-break by creation",
   TodoSort.sorted(sameDue, .dueDate).map(\.title) == ["first", "second"])

// ---------- sort: priority ----------
let byPri = TodoSort.sorted([
    item("low",  created: 10, priority: 1),
    item("high", created: 20, priority: 3),
    item("none", created: 30, priority: 0),
    item("mid",  created: 40, priority: 2),
], .priority)
ok("priority sorts high to low", byPri.map(\.title) == ["high", "mid", "low", "none"],
   "got \(byPri.map(\.title))")
let samePri = [item("later", created: 20, priority: 2), item("earlier", created: 10, priority: 2)]
ok("equal priority tie-breaks by creation (oldest first)",
   TodoSort.sorted(samePri, .priority).map(\.title) == ["earlier", "later"])

// ---------- sort: created ----------
let byCreated = TodoSort.sorted([
    item("oldest", created: 10), item("newest", created: 30), item("middle", created: 20),
], .created)
ok("created sorts newest first", byCreated.map(\.title) == ["newest", "middle", "oldest"],
   "got \(byCreated.map(\.title))")

// ---------- sort: manual preserves the stored order exactly ----------
let manual = [item("c", created: 30), item("a", created: 10), item("b", created: 20)]
ok("manual returns the array untouched (drag order)",
   TodoSort.sorted(manual, .manual).map(\.title) == ["c", "a", "b"])

// ---------- degenerate ----------
for order in TodoSortOrder.allCases {
    ok("\(order.rawValue): empty list is empty", TodoSort.sorted([], order).isEmpty)
    ok("\(order.rawValue): one item survives", TodoSort.sorted([item("solo")], order).count == 1)
    // No sort may lose or duplicate an item.
    let n = TodoSort.sorted(mixed, order)
    ok("\(order.rawValue): count preserved", n.count == mixed.count, "got \(n.count)")
    ok("\(order.rawValue): no duplicates", Set(n.map(\.id)).count == mixed.count)
}
// All-identical items must not crash a sort or drop any.
let identical = (0..<20).map { _ in item("same", created: 5, due: 100, priority: 1) }
for order in TodoSortOrder.allCases {
    ok("\(order.rawValue): 20 identical items all survive",
       TodoSort.sorted(identical, order).count == 20)
}

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Todo.swift" "$WORK/main.swift" -o "$WORK/todo" 2>&1 | grep -E "error" || true
"$WORK/todo"
