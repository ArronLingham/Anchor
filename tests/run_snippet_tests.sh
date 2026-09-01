#!/bin/bash
# Pins SnippetMatcher, the logic that decides whether a typed abbreviation
# expands.
#
# This deserves a harness more than most: a wrong match here does not misdraw
# something, it *corrupts what the user is typing* — deleting the wrong number
# of characters, or firing inside a word. Both are silent and unrecoverable.
#
# Compiles the real TextSnippet.swift, minus its `Defaults.Serializable`
# conformance (which would drag in the SPM package for no benefit here).
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

sed 's/, Defaults\.Serializable//; /^import Defaults$/d' \
    Anchor/models/TextSnippet.swift > "$WORK/TextSnippet.swift"

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0

func snip(_ trigger: String, _ expansion: String, immediate: Bool = false) -> TextSnippet {
    TextSnippet(trigger: trigger, expansion: expansion, expandImmediately: immediate)
}

func check(_ label: String, buffer: String, snippets: [TextSnippet],
           expectTrigger: String?, expectDelete: Int? = nil) {
    let match = SnippetMatcher.match(buffer: buffer, snippets: snippets)
    let gotTrigger = match?.snippet.trigger
    var ok = gotTrigger == expectTrigger
    if ok, let expectDelete, match?.charactersToDelete != expectDelete { ok = false }
    if ok { passes += 1 } else {
        failures += 1
        print("  FAIL \(label)")
        print("       buffer: '\(buffer)'")
        print("       got:    \(gotTrigger ?? "nil") delete=\(match?.charactersToDelete ?? -1)")
        print("       want:   \(expectTrigger ?? "nil") delete=\(expectDelete.map(String.init) ?? "-")")
    }
}

let addr = snip(";addr", "1 Main St")
let a = snip(";a", "alpha")
let now = snip(";now", "NOW", immediate: true)

// --- terminator-committed expansion ---
check("fires on space", buffer: ";addr ", snippets: [addr],
      expectTrigger: ";addr", expectDelete: 6)          // trigger + terminator
check("fires on period", buffer: ";addr.", snippets: [addr], expectTrigger: ";addr")
check("fires on newline", buffer: ";addr\n", snippets: [addr], expectTrigger: ";addr")
check("no terminator yet", buffer: ";addr", snippets: [addr], expectTrigger: nil)

// --- longest trigger wins (the bug that makes long triggers untypable) ---
check("longest wins", buffer: ";addr ", snippets: [a, addr], expectTrigger: ";addr")
check("short still works", buffer: ";a ", snippets: [a, addr], expectTrigger: ";a")

// --- immediate expansion ---
check("immediate fires without terminator", buffer: "x;now", snippets: [now],
      expectTrigger: ";now", expectDelete: 4)            // trigger only
check("immediate not double-counted", buffer: ";now ", snippets: [now], expectTrigger: nil)

// --- must NOT fire ---
check("mid-word does not fire", buffer: "xx;addryy", snippets: [addr], expectTrigger: nil)
check("empty buffer", buffer: "", snippets: [addr], expectTrigger: nil)
check("no snippets", buffer: ";addr ", snippets: [], expectTrigger: nil)
check("blank trigger ignored", buffer: "anything ", snippets: [snip("", "x")], expectTrigger: nil)
check("blank expansion ignored", buffer: ";z ", snippets: [snip(";z", "")], expectTrigger: nil)
check("partial trigger", buffer: ";add ", snippets: [addr], expectTrigger: nil)

// --- placeholders ---
let ref = Date(timeIntervalSince1970: 1_756_000_000)
let en = Locale(identifier: "en_GB")
func expandCheck(_ label: String, _ expansion: String, clipboard: String?, contains: String) {
    let out = snip("t", expansion).expanded(now: ref, clipboardText: clipboard, locale: en)
    if out.contains(contains) { passes += 1 } else {
        failures += 1
        print("  FAIL \(label): got '\(out)', expected to contain '\(contains)'")
    }
}
expandCheck("clipboard placeholder", "x {clipboard} y", clipboard: "PASTED", contains: "PASTED")
expandCheck("nil clipboard -> empty", "x{clipboard}y", clipboard: nil, contains: "xy")
expandCheck("date placeholder", "{date}", clipboard: nil, contains: "2025")
expandCheck("literal text untouched", "no placeholders", clipboard: nil, contains: "no placeholders")

if failures == 0 {
    print("\(passes)/\(passes) passed")
    exit(0)
} else {
    print("\(passes) passed, \(failures) failed")
    exit(1)
}
SWIFT

swiftc -O "$WORK/TextSnippet.swift" "$WORK/main.swift" -o "$WORK/snip" 2>&1 | grep -E "error" || true
"$WORK/snip"
