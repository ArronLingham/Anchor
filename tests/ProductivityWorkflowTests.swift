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
