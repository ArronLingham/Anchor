// End-to-end tests for ClaudeTranscriptWatcher.
//
// Drives the real watcher against a temporary directory shaped like
// ~/.claude/projects, appends transcript lines to it, and asserts on the hits
// that come back. Run with ./tests/run_watcher_tests.sh.
//
// Nothing here touches the real ~/.claude tree.

import Foundation

var failures = 0
var checks = 0

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    checks += 1
    if condition {
        print("ok    \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    }
}

/// One transcript line as Claude Code writes them.
func line(type: String, timestamp: String, cwd: String, text: String) -> String {
    let object: [String: Any] = [
        "type": type,
        "timestamp": timestamp,
        "cwd": cwd,
        "message": ["content": [["type": "text", "text": text]]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    // Claude Code is a Node process, so its transcripts come from JSON.stringify,
    // which leaves "/" unescaped. Foundation escapes it as "\\/", which would put
    // a backslash inside the zone identifier and make TimeZone reject it. Undo it
    // so the fixture matches what really lands on disk — verified against a real
    // transcript, which contains "(America/Toronto)".
    let json = String(decoding: data, as: UTF8.self)
    return json.replacingOccurrences(of: "\\/", with: "/")
}

let BANNER = "You've hit your session limit \u{00B7} resets 8:10pm (America/Toronto)"

@main
struct ClaudeTranscriptWatcherTests {
    static func main() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "anchor-watcher-tests-\(UUID().uuidString)")
        let project = root.appending(path: "-Users-arronlingham-Anchor")
        try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lock = NSLock()
        var hits: [ClaudeTranscriptWatcher.Hit] = []
        let firstHit = DispatchSemaphore(value: 0)

        let watcher = ClaudeTranscriptWatcher(root: root) { hit in
            lock.lock(); hits.append(hit); lock.unlock()
            firstHit.signal()
        }
        watcher.start()
        defer { watcher.stop() }

        // FSEvents needs the stream live before the write it should notice.
        Thread.sleep(forTimeInterval: 1.0)

        let sessionId = "6ac991a9-031c-47c2-91e7-1a385df8e9dd"
        let transcript = project.appending(path: "\(sessionId).jsonl")
        let cwd = "/Users/arronlingham/Anchor"

        // A user-typed line quoting the banner must NOT count: anything pasted
        // or attached can contain one, and only the assistant stream is real.
        let decoy = line(type: "user", timestamp: "2026-08-24T20:59:00.000Z",
                         cwd: cwd, text: "here is what it printed: \(BANNER)")
        let real = line(type: "assistant", timestamp: "2026-08-24T21:00:00.000Z",
                        cwd: cwd, text: BANNER)

        try! (decoy + "\n" + real + "\n").write(to: transcript, atomically: false, encoding: .utf8)

        let arrived = firstHit.wait(timeout: .now() + 30)
        check("a banner in the assistant stream produces a hit", arrived == .success,
              "no hit within 30s")

        guard arrived == .success else { finish(); return }
        Thread.sleep(forTimeInterval: 1.0)   // let any duplicate land before counting

        lock.lock(); let captured = hits; lock.unlock()

        check("exactly one hit, so the quoted decoy was rejected",
              captured.count == 1, "got \(captured.count) hits")

        guard let hit = captured.first else { finish(); return }

        check("session id comes from the transcript filename",
              hit.sessionId == sessionId, "got \(hit.sessionId)")
        check("cwd is read from the line, not decoded from the directory name",
              hit.cwd == cwd, "got \(hit.cwd)")
        // FSEvents reports fully resolved paths, and /var is a symlink to
        // /private/var on macOS, so compare resolved forms.
        let reportedPath = URL(fileURLWithPath: hit.transcriptPath)
            .resolvingSymlinksInPath().path
        check("transcript path points at the file",
              reportedPath == transcript.resolvingSymlinksInPath().path,
              "got \(reportedPath)")

        // Banner says 8:10pm Toronto; the line is stamped 21:00Z = 17:00 EDT the
        // same day, so the reset is 20:10 EDT that day, i.e. 00:10Z the next.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Toronto")!
        let expected = cal.date(from: DateComponents(
            year: 2026, month: 8, day: 24, hour: 20, minute: 10))!
        check("reset resolves against the banner's zone, anchored on the line's timestamp",
              hit.limit.resetDate == expected,
              "expected \(expected), got \(hit.limit.resetDate)")
        check("zone is the one named in the banner",
              hit.limit.timeZone.identifier == "America/Toronto",
              "got \(hit.limit.timeZone.identifier)")

        finish()
    }

    static func finish() {
        print("")
        print("\(checks - failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
