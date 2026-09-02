#!/bin/bash
# Pins AIProtocol — multi-provider request construction and reply parsing.
#
# Renamed from run_gemini_tests.sh when the assistant grew past one provider.
# Two properties matter most, and both must hold for EVERY provider the
# abstraction grows, not just the one that was written first:
#
# 1. THE KEY IS NEVER IN THE URL. Google's own examples append `?key=…`, which
#    puts a billable credential into every proxy log, crash report and `nettop`
#    line. It belongs in a header — x-goog-api-key for Gemini, Authorization for
#    OpenAI. The test loops over all providers so a third one cannot quietly
#    regress this.
# 2. A TRIMMED HISTORY MUST NOT START WITH A MODEL TURN. Gemini 400s on that, so
#    a naive "keep the last N" fails on about half of all cut points —
#    intermittently, which is the worst way for it to fail.
#
# Also pinned: screenshot bytes reach the request body (the screen-vision path),
# and a message without an image does not smuggle an empty one.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Rules.swift" <<'PYX'
import re, sys
src = open("Anchor/Managers/Gemini/GeminiProtocol.swift").read()

def block(pattern):
    m = re.search(pattern, src)
    if not m:
        sys.exit("missing: " + pattern)
    i = m.start()
    depth, k = 0, src.index("{", i)
    while True:
        if src[k] == "{": depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0: break
        k += 1
    return src[i:k+1]

out = "\n\n".join([
    block(r'struct AIMessage\b'),
    block(r'enum AIProvider\b'),
    block(r'enum AIProtocol\b'),
])
# Defaults.Serializable needs the package; the types are otherwise pure.
out = out.replace(", Defaults.Serializable", "").replace("Defaults.Serializable, ", "")
out = re.sub(r'^\s*import .*$', '', out, flags=re.M)
open(sys.argv[1], "w").write("import Foundation\n\n" + out + "\n")
PYX

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}
func user(_ t: String) -> AIMessage { .init(role: .user, text: t) }
func model(_ t: String) -> AIMessage { .init(role: .model, text: t) }

// ---------- the credential rule, across EVERY provider ----------
for provider in AIProvider.allCases {
    guard let req = AIProtocol.buildRequest(provider: provider, model: "m",
              key: "SECRETKEY123", history: [user("hi")], systemInstruction: nil) else {
        // A provider with no implementation yet is acceptable; what is not
        // acceptable is half-building one.
        ok("\(provider.rawValue): unimplemented returns nil cleanly", true)
        continue
    }
    let url = req.url?.absoluteString ?? ""
    ok("\(provider.rawValue): key is NOT in the URL", !url.contains("SECRETKEY123"), url)
    ok("\(provider.rawValue): no query string at all", !url.contains("?"), url)
    ok("\(provider.rawValue): https", url.hasPrefix("https://"), url)
    ok("\(provider.rawValue): key travels in a header",
       (req.allHTTPHeaderFields ?? [:]).values.contains { $0.contains("SECRETKEY123") },
       "\((req.allHTTPHeaderFields ?? [:]).keys.sorted())")
    ok("\(provider.rawValue): POST", req.httpMethod == "POST")
    ok("\(provider.rawValue): body is valid JSON",
       req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil)
}

// Provider-specific header conventions.
if let g = AIProtocol.buildRequest(provider: .gemini, model: "m", key: "K",
                                   history: [user("x")], systemInstruction: nil) {
    ok("gemini uses x-goog-api-key", g.allHTTPHeaderFields?["x-goog-api-key"] == "K",
       "\(g.allHTTPHeaderFields ?? [:])")
    ok("gemini names the model in the path",
       g.url?.absoluteString.contains("models/m:generateContent") == true,
       g.url?.absoluteString ?? "")
}
if let o = AIProtocol.buildRequest(provider: .openai, model: "m", key: "K",
                                   history: [user("x")], systemInstruction: nil) {
    ok("openai uses Authorization: Bearer",
       o.allHTTPHeaderFields?["Authorization"] == "Bearer K",
       "\(o.allHTTPHeaderFields ?? [:])")
}

// ---------- screen vision: image bytes must reach the body ----------
var withImage = user("look at this")
withImage.imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])
for provider in [AIProvider.gemini, .openai] {
    guard let req = AIProtocol.buildRequest(provider: provider, model: "m", key: "K",
              history: [withImage], systemInstruction: nil),
          let b = req.httpBody else { continue }
    // Search the PARSED body, not its text. JSONSerialization escapes "/" as
    // "\\/", and this base64 is full of slashes — string-matching the raw body
    // fails for a reason that has nothing to do with the code under test.
    // (CLAUDE.md records the same trap in the Claude-usage fixtures.)
    let want = withImage.imageData!.base64EncodedString()
    func containsValue(_ any: Any) -> Bool {
        // Containment, not equality: Gemini stores the bare base64 while OpenAI
        // wraps it as "data:image/jpeg;base64,<b64>". Both are correct for their
        // API; only the envelope differs.
        if let s = any as? String { return s.contains(want) }
        if let d = any as? [String: Any] { return d.values.contains(where: containsValue) }
        if let a = any as? [Any] { return a.contains(where: containsValue) }
        return false
    }
    let parsed = (try? JSONSerialization.jsonObject(with: b)) ?? [:]
    ok("\(provider.rawValue): screenshot bytes reach the body", containsValue(parsed))
}
if let plain = AIProtocol.buildRequest(provider: .gemini, model: "m", key: "K",
       history: [user("no image")], systemInstruction: nil), let b = plain.httpBody {
    ok("no image means no inlineData",
       !(String(data: b, encoding: .utf8) ?? "").contains("inlineData"))
    ok("no image means no OpenAI image_url either",
       !(String(data: b, encoding: .utf8) ?? "").contains("image_url"))
}

// ---------- trimmed history never begins with a model turn ----------
let convo = [user("a"), model("b"), user("c"), model("d"), user("e"), model("f")]
for limit in 1...convo.count {
    let t = AIProtocol.trimmed(convo, limit: limit)
    ok("limit \(limit) does not start with a model turn", t.first?.role != .model,
       "\(t.map { $0.role.rawValue })")
}
ok("limit 0 is empty",              AIProtocol.trimmed(convo, limit: 0).isEmpty)
ok("negative limit is empty",       AIProtocol.trimmed(convo, limit: -3).isEmpty)
ok("all-model history trims away",  AIProtocol.trimmed([model("a"), model("b")], limit: 5).isEmpty)
ok("empty stays empty",             AIProtocol.trimmed([], limit: 5).isEmpty)
ok("limit beyond length keeps all", AIProtocol.trimmed(convo, limit: 99).count == convo.count)

// ---------- parsing, per provider ----------
func parse(_ p: AIProvider, _ s: String) -> AIProtocol.ParseResult {
    AIProtocol.parse(provider: p, data: Data(s.utf8))
}
ok("gemini reply", parse(.gemini, #"{"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}"#) == .reply("Hi"))
ok("openai reply", parse(.openai, #"{"choices":[{"message":{"content":"Hi"}}]}"#) == .reply("Hi"))

for (p, body) in [(AIProvider.gemini, #"{"error":{"message":"API key not valid","status":"INVALID_ARGUMENT"}}"#),
                  (AIProvider.openai, #"{"error":{"message":"Incorrect API key","type":"invalid_request_error"}}"#)] {
    if case .failure(let m) = parse(p, body) {
        ok("\(p.rawValue): error message surfaced", m.lowercased().contains("key"), m)
    } else { failures += 1; print("  FAIL \(p.rawValue): error not surfaced") }
}
for p in [AIProvider.gemini, .openai] {
    ok("\(p.rawValue): empty object is a failure",
       { if case .failure = parse(p, "{}") { return true }; return false }())
    ok("\(p.rawValue): non-json is a failure",
       { if case .failure = parse(p, "<html>502</html>") { return true }; return false }())
    ok("\(p.rawValue): empty body is a failure",
       { if case .failure = parse(p, "") { return true }; return false }())
}
// A blocked completion must not read as an empty assistant message.
ok("gemini blocked response explains itself",
   { if case .failure = parse(.gemini, #"{"candidates":[{"finishReason":"SAFETY","content":{"parts":[]}}]}"#) { return true }; return false }())

// ---------- model listing ----------
// The picker went stale because the list was hardcoded; enumerating is only an
// improvement if it keeps the same credential rule as everything else.
for provider in AIProvider.allCases {
    guard let req = AIProtocol.buildModelListRequest(provider: provider, key: "SECRETKEY123") else {
        ok("\(provider.rawValue): no model listing is acceptable", true)
        continue
    }
    let url = req.url?.absoluteString ?? ""
    ok("\(provider.rawValue) list: key is NOT in the URL", !url.contains("SECRETKEY123"), url)
    ok("\(provider.rawValue) list: no query string", !url.contains("?"), url)
    ok("\(provider.rawValue) list: https", url.hasPrefix("https://"), url)
    ok("\(provider.rawValue) list: GET", req.httpMethod == "GET")
    ok("\(provider.rawValue) list: key travels in a header",
       (req.allHTTPHeaderFields ?? [:]).values.contains { $0.contains("SECRETKEY123") })
}

// Gemini reports what each model can do; offering one that cannot
// generateContent produces a 400 the user cannot diagnose.
let geminiList = #"""
{"models":[
 {"name":"models/gemini-3.6-flash","supportedGenerationMethods":["generateContent","countTokens"]},
 {"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]},
 {"name":"models/gemini-3.5-flash-lite","supportedGenerationMethods":["generateContent"]}
]}
"""#
let gm = AIProtocol.parseModelList(provider: .gemini, data: Data(geminiList.utf8))
ok("gemini: keeps generateContent models", gm.contains("gemini-3.6-flash") && gm.contains("gemini-3.5-flash-lite"), "\(gm)")
ok("gemini: drops embedding-only models", !gm.contains("embedding-001"), "\(gm)")
ok("gemini: strips the models/ prefix", gm.allSatisfy { !$0.hasPrefix("models/") }, "\(gm)")

let openaiList = #"""
{"data":[{"id":"gpt-4o"},{"id":"o1-mini"},{"id":"text-embedding-3-small"},{"id":"whisper-1"},{"id":"tts-1"}]}
"""#
let om = AIProtocol.parseModelList(provider: .openai, data: Data(openaiList.utf8))
ok("openai: keeps chat models", om.contains("gpt-4o") && om.contains("o1-mini"), "\(om)")
ok("openai: drops embeddings, whisper and tts",
   !om.contains("text-embedding-3-small") && !om.contains("whisper-1") && !om.contains("tts-1"), "\(om)")

for p in AIProvider.allCases {
    ok("\(p.rawValue): garbage list parses to empty, not a crash",
       AIProtocol.parseModelList(provider: p, data: Data("<html>502</html>".utf8)).isEmpty)
    ok("\(p.rawValue): empty body parses to empty",
       AIProtocol.parseModelList(provider: p, data: Data()).isEmpty)
    // The picker must never be blank, or there is no way back from a bad model.
    ok("\(p.rawValue): fallback list is not empty", !AIProtocol.fallbackModels(for: p).isEmpty)
}

// Gemini returns "models/x" and users paste it that way; building
// ".../models/models/x" 404s.
for model in ["gemini-3.6-flash", "models/gemini-3.6-flash"] {
    if let r = AIProtocol.buildRequest(provider: .gemini, model: model, key: "K",
                                       history: [user("hi")], systemInstruction: nil) {
        let u = r.url?.absoluteString ?? ""
        ok("gemini accepts \(model)", u.contains("/models/gemini-3.6-flash:generateContent"), u)
        ok("gemini never doubles the prefix", !u.contains("models/models/"), u)
    }
}

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Rules.swift" "$WORK/main.swift" -o "$WORK/ai" 2>&1 | grep -E "error" || true
"$WORK/ai"
