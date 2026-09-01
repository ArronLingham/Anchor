#!/bin/bash
# Pins GeminiProtocol — request construction and reply parsing.
#
# Two properties matter most here and neither is obvious:
#
# 1. THE KEY IS NOT IN THE URL. Google's own examples append `?key=…`, and
#    copying that puts a billable credential into every proxy log, crash report
#    and `nettop` line. The endpoint must stay clean; the key travels in the
#    x-goog-api-key header.
# 2. A TRIMMED HISTORY MUST NOT START WITH A MODEL TURN. Gemini rejects that
#    with a 400, so a naive "keep the last N" fails roughly half the time —
#    intermittently, which is the worst way for it to fail.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Rules.swift" <<'PY'
import re, sys
src = open("Anchor/managers/Gemini/GeminiProtocol.swift").read()
msg = re.search(r'(struct GeminiMessage[^\{]*\{.*?\n\})\n', src, re.S).group(1)
pro = re.search(r'(enum GeminiProtocol \{.*?\n\})\n', src, re.S).group(1)
open(sys.argv[1], "w").write("import Foundation\n\n" + msg + "\n\n" + pro + "\n")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}
func user(_ t: String) -> GeminiMessage { .init(role: .user, text: t) }
func model(_ t: String) -> GeminiMessage { .init(role: .model, text: t) }

// ---------- endpoint: no credential in the URL ----------
let url = GeminiProtocol.endpoint()
ok("endpoint builds", url != nil)
if let s = url?.absoluteString {
    ok("no key query parameter", !s.contains("key="), s)
    ok("no query string at all",  !s.contains("?"), s)
    ok("https",                    s.hasPrefix("https://"))
    ok("names the model",          s.contains("gemini-2.0-flash"))
    ok("generateContent",          s.hasSuffix(":generateContent"))
}
ok("custom model is honoured",
   GeminiProtocol.endpoint(model: "gemini-1.5-pro")?.absoluteString.contains("gemini-1.5-pro") == true)

// ---------- trimmed: never starts with a model turn ----------
let convo = [user("a"), model("b"), user("c"), model("d"), user("e"), model("f")]
ok("keeps the last N",       GeminiProtocol.trimmed(convo, limit: 2).count <= 2)
ok("limit 0 is empty",       GeminiProtocol.trimmed(convo, limit: 0).isEmpty)
ok("negative limit is empty", GeminiProtocol.trimmed(convo, limit: -5).isEmpty)
ok("limit beyond length keeps all", GeminiProtocol.trimmed(convo, limit: 99).count == convo.count)

// The property that matters, over every possible cut point.
for limit in 1...convo.count {
    let t = GeminiProtocol.trimmed(convo, limit: limit)
    ok("limit \(limit) does not start with a model turn", t.first?.role != .model,
       "got \(t.map { $0.role.rawValue })")
}
// A conversation that is only model turns trims to nothing rather than to an
// invalid request.
ok("all-model history becomes empty",
   GeminiProtocol.trimmed([model("a"), model("b")], limit: 5).isEmpty)
ok("empty history stays empty", GeminiProtocol.trimmed([], limit: 5).isEmpty)

// ---------- requestBody ----------
let body = GeminiProtocol.requestBody(history: [user("hello")], systemInstruction: "be brief")
ok("has contents", body["contents"] != nil)
ok("has systemInstruction", body["systemInstruction"] != nil)
if let contents = body["contents"] as? [[String: Any]] {
    ok("one turn", contents.count == 1)
    ok("role is user", contents[0]["role"] as? String == "user")
    let parts = contents[0]["parts"] as? [[String: String]]
    ok("text survives", parts?.first?["text"] == "hello")
}
// An empty system instruction is omitted rather than sent blank.
ok("empty system instruction is omitted",
   GeminiProtocol.requestBody(history: [user("x")], systemInstruction: "")["systemInstruction"] == nil)
ok("nil system instruction is omitted",
   GeminiProtocol.requestBody(history: [user("x")], systemInstruction: nil)["systemInstruction"] == nil)
// The body must be real JSON — a dictionary that cannot serialise fails at
// runtime with no useful message.
ok("body serialises to JSON",
   (try? JSONSerialization.data(withJSONObject: body)) != nil)

// ---------- parse ----------
func parse(_ s: String) -> GeminiProtocol.ParseResult { GeminiProtocol.parse(Data(s.utf8)) }

ok("normal reply",
   parse(#"{"candidates":[{"content":{"parts":[{"text":"Hi there"}],"role":"model"}}]}"#)
   == .reply("Hi there"))
ok("multi-part reply is joined",
   parse(#"{"candidates":[{"content":{"parts":[{"text":"a"},{"text":"b"}]}}]}"#) == .reply("ab"))

// Errors are surfaced, not swallowed.
if case .failure(let m) = parse(#"{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}"#) {
    ok("error message surfaced", m.contains("API key not valid"), m)
    ok("error status included",  m.contains("INVALID_ARGUMENT"), m)
} else { failures += 1; print("  FAIL API error not surfaced") }

// A blocked response has a finishReason and no text. Reporting that as an
// empty assistant message would look like the app was broken.
if case .failure(let m) = parse(#"{"candidates":[{"finishReason":"SAFETY","content":{"parts":[]}}]}"#) {
    ok("blocked response explains itself", m.contains("SAFETY"), m)
} else { failures += 1; print("  FAIL blocked response parsed as a reply") }

ok("whitespace-only reply is not a reply",
   parse(#"{"candidates":[{"content":{"parts":[{"text":"   "}]}}]}"#) != .reply("   "))
ok("no candidates",   { if case .failure = parse(#"{"candidates":[]}"#) { return true }; return false }())
ok("empty object",    { if case .failure = parse("{}") { return true }; return false }())
ok("not json",        { if case .failure = parse("<html>502</html>") { return true }; return false }())
ok("empty body",      { if case .failure = parse("") { return true }; return false }())

// ---------- looksLikeAPIKey ----------
ok("a realistic key passes", GeminiProtocol.looksLikeAPIKey("AIzaSyD-1234567890abcdefghijklmnop"))
ok("too short rejected",     !GeminiProtocol.looksLikeAPIKey("abc"))
ok("empty rejected",         !GeminiProtocol.looksLikeAPIKey(""))
ok("spaces rejected",        !GeminiProtocol.looksLikeAPIKey("AIzaSy with a space in it here"))
ok("newline rejected",       !GeminiProtocol.looksLikeAPIKey("AIzaSyD-1234567890abcdef\nghij"))
ok("surrounding whitespace tolerated",
   GeminiProtocol.looksLikeAPIKey("  AIzaSyD-1234567890abcdefghijklmnop  "))
// Deliberately permissive: Google has changed key formats, and a validator
// that is too strict locks the user out of a key that actually works.
ok("an unfamiliar but plausible key is accepted",
   GeminiProtocol.looksLikeAPIKey("xyz_9999999999999999999999"))

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Rules.swift" "$WORK/main.swift" -o "$WORK/g" 2>&1 | grep -E "error" || true
"$WORK/g"
