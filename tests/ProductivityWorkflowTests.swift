import AppKit
import Foundation

@main
struct ProductivityWorkflowTests {
    static var checks = 0
    static var failures = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !value() { failures += 1; print("FAIL: " + label) }
    }

    static func main() throws {
        check(!AppleNotesSyncPolicy.permitsNewWork(notesEnabled: false, syncEnabled: true), "notes off blocks new Apple Notes work while retaining the sync preference")
        check(!AppleNotesSyncPolicy.permitsNewWork(notesEnabled: true, syncEnabled: false), "sync off blocks Apple Notes work while leaving notes available")
        check(AppleNotesSyncPolicy.permitsNewWork(notesEnabled: true, syncEnabled: true), "both controls enable Apple Notes work")
        struct NoteFixture: Identifiable, Equatable {
            let id: Int
            var body: String
            var remoteID: String? = nil
        }
        let baseline = [NoteFixture(id: 1, body: "original"), NoteFixture(id: 2, body: "deleted locally"), NoteFixture(id: 3, body: "unchanged")]
        let syncResult = [NoteFixture(id: 1, body: "remote edit"), NoteFixture(id: 2, body: "remote edit"), NoteFixture(id: 3, body: "updated"), NoteFixture(id: 4, body: "imported")]
        let current = [NoteFixture(id: 1, body: "local edit", remoteID: "acknowledged"), NoteFixture(id: 3, body: "unchanged"), NoteFixture(id: 5, body: "new local")]
        let reconciled = AppleNotesSnapshotReconciliation.merge(baseline: baseline, result: syncResult, current: current)
        check(reconciled.first(where: { $0.id == 1 }) == current[0], "sync preserves a newer local edit and an acknowledged remote link")
        check(!reconciled.contains(where: { $0.id == 2 }), "sync does not resurrect a note deleted locally during the fetch")
        check(reconciled.first(where: { $0.id == 3 })?.body == "updated", "unchanged local notes receive remote updates")
        check(reconciled.contains(where: { $0.id == 4 }) && reconciled.contains(where: { $0.id == 5 }), "sync keeps both newly imported and newly created local notes")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = utc.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 7))!
        let firstDraw = DailyCommitCountPolicy.draw(day: day, seed: 12345, minimum: 2, maximum: 5, calendar: utc)
        let sameDay = day.addingTimeInterval(12 * 3600)
        check(firstDraw == DailyCommitCountPolicy.draw(day: sameDay, seed: 12345, minimum: 2, maximum: 5, calendar: utc), "random daily count stays stable throughout a day")
        check((2...5).contains(firstDraw), "random daily count is within the inclusive range")
        var otherZone = utc
        otherZone.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        check(firstDraw == DailyCommitCountPolicy.draw(day: day, seed: 12345, minimum: 2, maximum: 5, calendar: otherZone), "the same local date has the same target after a time zone change")
        check(DailyCommitCountPolicy.draw(day: day, seed: 12345, minimum: 7, maximum: 7, calendar: utc) == 7, "equal bounds select exactly that count")
        check(DailyCommitCountPolicy.bounds(8, 3) == 3...8, "reversed bounds are normalized")
        check(DailyCommitCountPolicy.bounds(Int.min, Int.max) == 0...(Int.max - 1), "invalid extreme bounds are safely limited")
        check(DailyCommitCountPolicy.draw(day: day, seed: 12345, minimum: 0, maximum: 0, calendar: utc) == 0, "zero bounds select a day without commits")
        let draws = Set((0..<30).map { DailyCommitCountPolicy.draw(day: day.addingTimeInterval(Double($0) * 86400), seed: 12345, minimum: 2, maximum: 5, calendar: utc) })
        check(draws == Set(2...5), "the seeded daily draw reaches both inclusive bounds")
        let windowEnd = day.addingTimeInterval(10 * 3600)
        let spread = DailyCommitCountPolicy.nextCatchUp(after: day, end: windowEnd, remaining: 24)!
        check(spread.timeIntervalSince(day) > 60 && spread < windowEnd, "overdue work is spread through the remaining window")
        check(DailyCommitCountPolicy.nextCatchUp(after: windowEnd, end: windowEnd, remaining: 1) == nil, "no catch-up is scheduled after the window")
        let runGate = DailyCommitRunGate()
        check(runGate.begin() && !runGate.begin(), "concurrent commit runs cannot claim the same slot")
        runGate.end()
        check(runGate.begin(), "a completed run releases the next slot")
        runGate.end()
        let search = AnchorQuicklink(title: "Search", keyword: "g", target: "https://example.com/search?q={query}")
        check(search.validationError == nil, "search template is valid")
        let query = "café + swift & sort=private#fragment"
        let result = search.resolvedURL(query: query)!
        let components = URLComponents(url: result, resolvingAgainstBaseURL: false)!
        check(components.queryItems?.count == 1, "query cannot inject another parameter")
        check(components.queryItems?.first?.value == query, "Unicode and reserved characters round-trip")
        check(result.fragment == nil, "query cannot inject a fragment")
        check(search.argument(in: "G hello world") == "hello world", "keyword case and spaced arguments")
        check(search.argument(in: "garage") == nil, "keyword does not steal application prefixes")
        check(search.argument(in: "g") == "", "empty search argument is distinguishable")
        check(AnchorQuicklink(title: "", keyword: "g", target: "https://example.com").validationError != nil, "empty name is refused")
        check(AnchorQuicklink(title: "Bad", keyword: "two words", target: "https://example.com").validationError != nil, "space in keyword is refused")
        check(AnchorQuicklink(title: "Bad", keyword: "bad", target: "javascript:alert(1)").validationError != nil, "executable URL scheme is refused")
        check(AnchorQuicklink(title: "File", keyword: "file", target: URL(fileURLWithPath: "/tmp/My File.txt").absoluteString).resolvedURL(query: "")?.isFileURL == true, "local file link preserves spaces")
        check(AnchorQuicklink.directWebURL("example.com/docs")?.absoluteString == "https://example.com/docs", "bare domain opens with https")
        check(AnchorQuicklink.directWebURL("calculator") == nil, "application text is not a URL")
        check(AnchorQuicklink.directWebURL("https://user:password@example.com") == nil, "URL credentials are not silently opened")
        check(AnchorQuicklink.directWebURL("file:///private/etc/passwd") == nil, "direct URL results do not open local paths")
        check(AnchorQuicklink.directWebURL("../readme.md") == nil, "relative file is not a web address")
        let linkRoundTrip = try JSONDecoder().decode(AnchorQuicklink.self, from: JSONEncoder().encode(search))
        check(linkRoundTrip == search, "quicklinks persist without changing identity")

        let document = ClipboardSearchDocument(type: "text", text: String(repeating: "a", count: 70) + " hidden needle", source: "Safari com.apple.Safari", collection: "Work")
        check(document.matches("needle"), "search reaches content beyond the short preview")
        check(document.matches("@text @app:Safari needle"), "type, app and text filters combine")
        check(document.matches("@safari @board:Work hidden"), "app shorthand and collection filters combine")
        check(!document.matches("@image needle"), "wrong content type is excluded")
        check(!document.matches("@app:Chrome"), "wrong source app is excluded")
        check(ClipboardSearchDocument(type: "rtf", text: "Rich", source: "", collection: "").matches("@text @rich"), "rich text participates in text searches")
        check(ClipboardSearchDocument(type: "image", text: "Screenshot", source: "", collection: "").matches("@image"), "image filtering")
        check(ClipboardSearchDocument(type: "url", text: "https://example.com", source: "", collection: "").matches("@link"), "link filtering")
        check(ClipboardSearchDocument(type: "file", text: "/tmp/report.pdf", source: "Finder", collection: "").matches("@file report"), "file names are searched")
        for marker in ClipboardCapturePolicy.sensitiveTypes {
            check(!ClipboardCapturePolicy.permits(types: [marker], source: nil, ignoredApps: [], skipSensitive: true), "private marker is skipped: " + marker)
        }
        check(!ClipboardCapturePolicy.permits(types: [], source: "private.app", ignoredApps: ["private.app"], skipSensitive: true), "excluded application is skipped")
        check(ClipboardCapturePolicy.permits(types: [], source: nil, ignoredApps: [], skipSensitive: true), "unknown source does not discard normal copies")
        check(!ClipboardCapturePolicy.shouldPoll(isMonitoring: true, isPaused: false, isSuspended: true), "starting or resuming while locked does not poll")
        check(!ClipboardCapturePolicy.shouldPoll(isMonitoring: true, isPaused: true, isSuspended: false), "waking while capture is paused does not poll")
        check(!ClipboardCapturePolicy.shouldPoll(isMonitoring: false, isPaused: false, isSuspended: false), "a stopped watcher does not poll")
        check(ClipboardCapturePolicy.shouldPoll(isMonitoring: true, isPaused: false, isSuspended: false), "an active, unpaused watcher polls after wake")
        check(!ClipboardCapturePolicy.needsWatcher(history: false, cleanURLs: false, autoClear: false), "no clipboard consumer leaves the watcher off")
        check(ClipboardCapturePolicy.needsWatcher(history: true, cleanURLs: false, autoClear: false), "history keeps the watcher running")
        check(ClipboardCapturePolicy.needsWatcher(history: false, cleanURLs: true, autoClear: false), "URL cleaning keeps the watcher running without history")
        check(ClipboardCapturePolicy.needsWatcher(history: false, cleanURLs: false, autoClear: true), "auto-clear keeps the watcher running without history")
        check(ClipboardCapturePolicy.shouldClear(expectedChangeCount: 10, currentChangeCount: 10), "delay clears the copy that armed it")
        check(!ClipboardCapturePolicy.shouldClear(expectedChangeCount: 10, currentChangeCount: 11), "delay does not clear a newer copy")
        check(ClipboardCapturePolicy.shouldClear(expectedChangeCount: nil, currentChangeCount: 11), "lock and sleep clears do not depend on a prior copy")
        check(SystemActivityGate.sessionLockStatus(from: nil) == nil, "an unavailable session stays unknown")
        check(SystemActivityGate.sessionLockStatus(from: [:]) == false, "a session without the lock key is unlocked")
        check(SystemActivityGate.sessionLockStatus(from: ["CGSSessionScreenIsLocked": true]) == true, "a locked session is detected at startup")
        let now = Date(timeIntervalSince1970: 2_000_000)
        check(ClipboardCapturePolicy.isExpired(timestamp: now.addingTimeInterval(-86_400), retentionDays: 1, now: now), "expiry applies at its exact boundary")
        check(!ClipboardCapturePolicy.isExpired(timestamp: now.addingTimeInterval(-86_399), retentionDays: 1, now: now), "history remains just before expiry")
        check(!ClipboardCapturePolicy.isExpired(timestamp: .distantPast, retentionDays: 0, now: now), "unlimited retention remains unlimited")
        check(!ClipboardCapturePolicy.safeImageName("../other.txt"), "backup filename cannot traverse directories")
        check(!ClipboardCapturePolicy.safeImageName("/tmp/other.txt"), "absolute backup image path is refused")
        check(ClipboardCapturePolicy.safeImageName("clipboard_image_123.png"), "owned image filename is accepted")
        check(ClipboardTextTransform.trim.apply(" \n hi \t") == "hi", "whitespace trim")
        check(ClipboardTextTransform.joinLines.apply(" one\n\n two ") == "one two", "join lines")
        check(ClipboardTextTransform.removeEmptyLines.apply("a\n \nb") == "a\nb", "remove empty lines")
        check(ClipboardTextTransform.uniqueLines.apply("a\na\nb\na") == "a\nb", "duplicate lines preserve first order")
        check(ClipboardTextTransform.uppercase.apply("café") == "CAFÉ", "Unicode text transformation")
        check(ClipboardTextTransform.sortLines.apply("file10\nfile2") == "file2\nfile10", "natural line sorting")
        let original = ClipboardItem(stringData: "legacy text", type: .text)
        let oldData = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: oldData)
        check(decoded.id == original.id && decoded.stringData == original.stringData, "existing clipboard items keep identity and content")
        check(decoded.sourceAppName == nil && decoded.collectionName == nil, "legacy metadata remains optional")

        for diameter in [CGFloat(40), 65, 90, 200, .nan, -.infinity, -100, 9_000] {
            let layout = CircularHUDLayout(diameter: diameter, stroke: 999)
            check(layout.diameter.isFinite && (40...200).contains(layout.diameter), "diameter is finite and bounded")
            check(layout.stroke <= layout.diameter * 0.12, "ring thickness remains proportional")
            for bounds in [CGRect(x: 0, y: 24, width: 1_440, height: 820), CGRect(x: -1_920, y: -200, width: 1_920, height: 1_080)] {
                let frame = layout.frame(in: bounds)
                check(abs(frame.midX - bounds.midX) <= 0.5 && abs(frame.midY - bounds.midY) <= 0.5, "circle remains centered on either display")
            }
        }
        for value in [CGFloat(0), 0.06, 0.65, 1] {
            let point = CircularHUDLayout(diameter: 65).knobOffset(value: value)
            check(abs(hypot(point.x, point.y) - 32.5) < 0.001, "knob stays on its arc")
        }
        check(CircularHUDLayout.percentage(0.06) == "6", "one-digit label has no leading spaces")
        check(CircularHUDLayout.percentage(0.65) == "65", "two-digit label has no leading spaces")
        check(CircularHUDLayout.percentage(1) == "100", "full value remains centered text")
        check(CircularHUDLayout.percentage(.nan) == "0", "invalid value does not trap")

        var configuration = FocusCycleConfiguration()
        configuration.focusMinutes = -10
        check(configuration.duration(for: .focus) == 60, "focus duration clamps invalid settings")
        configuration.focusMinutes = 25
        var focus = FocusCycleState()
        focus.deadline = now.addingTimeInterval(60)
        check(focus.remaining(at: now) == 60, "deadline tracks wall-clock time")
        focus.pausedRemaining = 40
        check(focus.remaining(at: now.addingTimeInterval(3_600)) == 40, "paused session does not elapse")
        focus.pausedRemaining = nil
        check(focus.completePhase(configuration: configuration), "focus completion is counted")
        check(focus.phase == .shortBreak && focus.completedRounds == 1, "first round schedules a short break")
        check(!focus.completePhase(configuration: configuration) && focus.completedRounds == 1, "duplicate completion does not count again")
        for _ in 1...3 {
            focus.awaitingNext = false; focus.deadline = now; _ = focus.completePhase(configuration: configuration)
            focus.awaitingNext = false; focus.deadline = now; _ = focus.completePhase(configuration: configuration)
        }
        check(focus.completedRounds == 4 && focus.phase == .longBreak, "fourth focus session schedules a long break")
        let persisted = try JSONDecoder().decode(FocusCycleState.self, from: JSONEncoder().encode(focus))
        check(persisted == focus, "focus cycle resumes with identical persisted state")

        var panel = LockScreenPresentationState()
        let firstShow = panel.present()
        panel.setMediaAvailable(true)
        check(panel.shouldBeVisible(isLocked: true, isEnabled: true), "active media appears on a locked screen")
        panel.setMediaAvailable(false)
        check(!panel.shouldBeVisible(isLocked: true, isEnabled: true), "ended media leaves no invisible fullscreen window")
        panel.setMediaAvailable(true)
        check(panel.shouldBeVisible(isLocked: true, isEnabled: true), "media returning can show without a new lock event")
        check(!panel.shouldBeVisible(isLocked: false, isEnabled: true), "media never presents after unlock")
        check(!panel.shouldBeVisible(isLocked: true, isEnabled: false), "disabled widget stays hidden")
        check(panel.canPresent(firstShow), "current presentation may become visible")
        let oldHide = panel.hide()
        let newShow = panel.present()
        check(!panel.canFinishHiding(oldHide), "cancelled old hide cannot remove a new panel")
        check(!panel.canPresent(firstShow) && panel.canPresent(newShow), "stale show cannot resurrect the old player")
        let finalHide = panel.hide()
        check(!panel.canPresent(newShow) && panel.canFinishHiding(finalHide), "unlock invalidates pending show")
        var stressPassed = true
        for _ in 0..<10_000 {
            _ = panel.present(); let stale = panel.hide(); _ = panel.present()
            stressPassed = stressPassed && !panel.canFinishHiding(stale)
        }
        check(stressPassed, "10,000 rapid lock/unlock/lock cycles reject stale hides")
        print("Productivity workflows: \(checks - failures)/\(checks) passed")
        if failures != 0 { exit(1) }
    }
}
