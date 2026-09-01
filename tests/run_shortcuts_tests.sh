#!/bin/bash
# Pins ShortcutsCatalog — parsing `shortcuts list` and deciding what may run.
#
# The safety half is the point. A shortcut name is user-controlled text that
# this code turns into a process invocation, so the obvious instinct is to
# sanitise it. That instinct is WRONG here and the tests below encode why: the
# name is passed as a single `Process.arguments` element, so there is no shell
# to escape for. `;`, `$(…)`, backticks and quotes are inert, and a shortcut
# genuinely named "Backup; now" must still run. Stripping those characters
# would break real shortcuts while defending against nothing.
#
# What IS rejected is only what cannot be a valid argv element or a valid
# shortcut name: empty, whitespace-only, embedded NUL (truncates the argument)
# and embedded newline (impossible in a name; means the parse went wrong).
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Rules.swift" <<'PY'
import re, sys
src = open("Anchor/managers/Launcher/ShortcutsManager.swift").read()
e = re.search(r'(enum ShortcutsCatalog \{.*?\n\})\n', src, re.S).group(1)
open(sys.argv[1], "w").write("import Foundation\n\n" + e + "\n")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}

// ---------- parse: the REAL output from this machine ----------
let real = """
Choose from List
Add Note
Time to Work
Change Recording Playback Setting
Take a Break
"""
let parsed = ShortcutsCatalog.parse(real)
ok("parses the real list", parsed.count == 5, "got \(parsed.count)")
ok("keeps names with spaces", parsed.contains("Change Recording Playback Setting"))
ok("preserves order", parsed.first == "Choose from List")

// Blank lines and trailing newlines are normal in CLI output.
ok("trailing newline",  ShortcutsCatalog.parse("A\nB\n").count == 2)
ok("blank lines dropped", ShortcutsCatalog.parse("A\n\n\nB").count == 2)
ok("whitespace trimmed", ShortcutsCatalog.parse("  A  \n B ") == ["A", "B"])
ok("empty output",      ShortcutsCatalog.parse("").isEmpty)
ok("only newlines",     ShortcutsCatalog.parse("\n\n\n").isEmpty)

// Names are kept verbatim — these are all legal shortcut names.
for name in ["Émoji ✨ Shortcut", "Backup (daily)", "50% brightness",
             "a/b", "Ünïcôdé", "Shortcut #1", "it's mine"] {
    ok("preserves \"\(name)\"", ShortcutsCatalog.parse(name) == [name])
}

// ---------- isRunnable: permissive by design ----------
// Shell metacharacters must be ACCEPTED. There is no shell in the run path,
// and rejecting these would break real shortcuts to defend against nothing.
for name in ["Backup; now", "Do $(whoami)", "back`tick`", "quote\"inside",
             "single'quote", "pipe|name", "amp&name", "redirect>name",
             "rm -rf /", "--help", "-n", "$HOME", "*", "~"] {
    ok("accepts shell-ish name \"\(name)\"", ShortcutsCatalog.isRunnable(name))
}

// Rejected: only what cannot be a valid argv element or shortcut name.
ok("rejects empty",            !ShortcutsCatalog.isRunnable(""))
ok("rejects whitespace only",  !ShortcutsCatalog.isRunnable("   "))
ok("rejects tab only",         !ShortcutsCatalog.isRunnable("\t"))
ok("rejects embedded NUL",     !ShortcutsCatalog.isRunnable("a\0b"))
ok("rejects embedded newline", !ShortcutsCatalog.isRunnable("a\nb"))
ok("rejects carriage return",  !ShortcutsCatalog.isRunnable("a\rb"))

// ---------- runArguments: argv, never a command line ----------
ok("argv for a simple name", ShortcutsCatalog.runArguments(for: "Add Note") == ["run", "Add Note"])
ok("name stays ONE argv element",
   ShortcutsCatalog.runArguments(for: "Add Note")?.count == 2)
// The critical property: a name full of shell syntax is still exactly one
// argument, unquoted and unsplit. If this ever returns 3+ elements for one
// name, something has started splitting on whitespace.
if let argv = ShortcutsCatalog.runArguments(for: "Backup; rm -rf / #now") {
    ok("dangerous-looking name is one argv element", argv.count == 2, "got \(argv)")
    ok("dangerous-looking name is unmodified", argv[1] == "Backup; rm -rf / #now", "got \(argv[1])")
} else { failures += 1; print("  FAIL dangerous-looking name was rejected — it should run") }

ok("no argv for an unrunnable name", ShortcutsCatalog.runArguments(for: "") == nil)
ok("no argv for a NUL name",         ShortcutsCatalog.runArguments(for: "a\0b") == nil)

// argv[0] is always the subcommand, never the name — a transposition here
// would run a shortcut called "run".
for name in ["Add Note", "run", "list", "--version"] where ShortcutsCatalog.isRunnable(name) {
    ok("subcommand first for \"\(name)\"", ShortcutsCatalog.runArguments(for: name)?[0] == "run")
}

// Every name the parser accepts must also be runnable — otherwise the launcher
// lists shortcuts that silently do nothing when selected.
for name in ShortcutsCatalog.parse(real) {
    ok("listed \"\(name)\" is runnable", ShortcutsCatalog.isRunnable(name))
}

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Rules.swift" "$WORK/main.swift" -o "$WORK/sc" 2>&1 | grep -E "error" || true
"$WORK/sc"
