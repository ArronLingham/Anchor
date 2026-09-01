#!/bin/bash
# Pins ClaudeSessionRegistry.SessionRecord decoding.
#
# Claude Code writes one <pid>.json per running process and adds or drops keys
# between versions. The property that matters: a file written by a DIFFERENT
# version must decode as far as it can, or be skipped — it must never take the
# whole session enumeration down with it, because that silently disables
# auto-resume for every session at once.
#
# Every field beyond sessionId is optional for exactly that reason, and this
# harness proves it rather than trusting the annotation.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Rec.swift" <<'PYX'
import re, sys
src = open("Anchor/Managers/ClaudeUsage/ClaudeSessionRegistry.swift").read()
m = re.search(r'(    private struct SessionRecord: Decodable \{.*?\n    \})', src, re.S)
rec = m.group(1).replace("    private struct", "struct").replace("\n    ", "\n")
open(sys.argv[1], "w").write("import Foundation\n\n" + rec + "\n")
PYX

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}
func decode(_ s: String) -> SessionRecord? {
    try? JSONDecoder().decode(SessionRecord.self, from: Data(s.utf8))
}

// ---------- a full, current-version record ----------
let full = #"{"pid":4242,"sessionId":"abc-123","cwd":"/Users/x/proj","name":"work","startedAt":1700000000.5}"#
if let r = decode(full) {
    ok("pid decoded",       r.pid == 4242)
    ok("sessionId decoded", r.sessionId == "abc-123")
    ok("cwd decoded",       r.cwd == "/Users/x/proj")
    ok("name decoded",      r.name == "work")
    ok("startedAt decoded", r.startedAt == 1_700_000_000.5)
} else { failures += 1; print("  FAIL full record did not decode") }

// ---------- version tolerance: only sessionId is required ----------
ok("sessionId alone decodes", decode(#"{"sessionId":"only"}"#) != nil)
ok("missing pid is tolerated",       decode(#"{"sessionId":"a","cwd":"/x"}"#)?.pid == nil)
ok("missing cwd is tolerated",       decode(#"{"sessionId":"a","pid":1}"#)?.cwd == nil)
ok("missing startedAt is tolerated", decode(#"{"sessionId":"a","pid":1}"#)?.startedAt == nil)
ok("missing name is tolerated",      decode(#"{"sessionId":"a","pid":1}"#)?.name == nil)

// A FUTURE version adding keys must still decode — this is the case that
// breaks enumeration for everyone if the struct is strict.
ok("unknown keys from a newer version are ignored",
   decode(#"{"sessionId":"a","pid":1,"brandNewField":true,"another":{"nested":[1,2]}}"#) != nil)

// Explicit nulls, which some writers emit instead of omitting the key.
ok("explicit nulls decode as nil",
   decode(#"{"sessionId":"a","pid":null,"cwd":null,"name":null,"startedAt":null}"#)?.pid == nil)

// ---------- rejection: the one required field ----------
ok("missing sessionId is rejected",  decode(#"{"pid":1,"cwd":"/x"}"#) == nil)
ok("null sessionId is rejected",     decode(#"{"sessionId":null}"#) == nil)
ok("wrong type for sessionId is rejected", decode(#"{"sessionId":123}"#) == nil)
ok("empty object is rejected",       decode("{}") == nil)
ok("truncated json is rejected",     decode(#"{"sessionId":"a""#) == nil)
ok("not json at all is rejected",    decode("this is not json") == nil)
ok("empty string is rejected",       decode("") == nil)
ok("a json array is rejected",       decode("[]") == nil)

// A wrong type on an OPTIONAL field still fails that record — which is correct,
// because the alternative is silently mis-reading a pid.
ok("wrong type for pid rejects the record", decode(#"{"sessionId":"a","pid":"notanint"}"#) == nil)

// ---------- realistic edge content ----------
ok("empty sessionId still decodes (filtering is the caller's job)",
   decode(#"{"sessionId":""}"#)?.sessionId == "")
ok("a path with spaces and unicode",
   decode(#"{"sessionId":"a","cwd":"/Users/x/My Café/proj"}"#)?.cwd == "/Users/x/My Café/proj")
ok("a hyphenated path survives (the directory name is lossy, the cwd field is not)",
   decode(#"{"sessionId":"a","cwd":"/Users/x/my-hyphen-project"}"#)?.cwd == "/Users/x/my-hyphen-project")
ok("pid 0 decodes",        decode(#"{"sessionId":"a","pid":0}"#)?.pid == 0)
ok("a large pid decodes",  decode(#"{"sessionId":"a","pid":99999}"#)?.pid == 99999)
ok("integer startedAt decodes as Double",
   decode(#"{"sessionId":"a","startedAt":1700000000}"#)?.startedAt == 1_700_000_000)

// ---------- the whole-list property ----------
// One bad file among good ones must cost only that file. compactMap gives this,
// and the test states it so nobody replaces it with a throwing map.
let files = [full, #"{"sessionId":"b"}"#, "GARBAGE", #"{"sessionId":"c","pid":7}"#, "{}"]
let decoded = files.compactMap(decode)
ok("three of five files survive; the bad ones are skipped, not fatal",
   decoded.count == 3, "got \(decoded.count)")
ok("the good records are the ones kept",
   decoded.map(\.sessionId) == ["abc-123", "b", "c"], "got \(decoded.map(\.sessionId))")

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Rec.swift" "$WORK/main.swift" -o "$WORK/rec" 2>&1 | grep -E "error" || true
"$WORK/rec"
