import AppKit

enum AppFeature {
    case windowLayout
    static var enabled = true
    var isAvailable: Bool { Self.enabled }
}

enum WindowLayoutAction { case maximize }
enum WindowLayoutResult { case success, failure }

final class LayoutFixture {
    static let shared = LayoutFixture()
    static let availabilityGate = ClipboardPresentationGate()
    var focusedWindow = "first"
    var touchedWindows: [String] = []
    var result = WindowLayoutResult.success

    func apply(_ action: WindowLayoutAction) -> WindowLayoutResult {
        touchedWindows.append(focusedWindow)
        return result
    }
}

@main struct WindowLayoutDeferredActionTests {
    static func main() {
        let fixture = LayoutFixture.shared
        let initial = LayoutFixture.captureAvailability()!
        let oldFeature = LayoutFixture.deferredAction(.maximize, availability: initial)!
        AppFeature.enabled = false
        LayoutFixture.availabilityGate.update(available: false)
        oldFeature()
        precondition(fixture.touchedWindows.isEmpty)
        precondition(LayoutFixture.captureAvailability() == nil)
        AppFeature.enabled = true
        LayoutFixture.availabilityGate.update(available: true)
        oldFeature()
        precondition(LayoutFixture.deferredAction(.maximize, availability: initial) == nil)

        let current = LayoutFixture.captureAvailability()!
        let oldLogin = LayoutFixture.deferredAction(.maximize, availability: current)!
        sessionNotifications.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        precondition(LayoutFixture.deferredAction(.maximize, availability: current) == nil)
        sessionNotifications.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        oldLogin()
        precondition(fixture.touchedWindows.isEmpty)

        var failures = 0
        let fresh = LayoutFixture.deferredAction(.maximize, availability: current) { failures += 1 }!
        fixture.focusedWindow = "behind launcher"
        fresh()
        precondition(fixture.touchedWindows == ["behind launcher"] && failures == 0)

        fixture.result = .failure
        fresh()
        precondition(failures == 1)
        LayoutFixture.availabilityGate.update(available: false)
        fresh()
        precondition(fixture.touchedWindows.count == 2 && failures == 1)
        print("Window Layout deferred action and login-session checks passed")
    }
}
