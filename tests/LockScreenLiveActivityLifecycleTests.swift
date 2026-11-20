import Foundation

struct Animation {
    static func smooth(duration: Double) -> Self { Self() }
}
func withAnimation(_ animation: Animation, _ action: () -> Void) { action() }
struct CAMediaTimingFunction {
    enum Name { case easeInEaseOut }
    init(name: Name) {}
}
struct NSAnimationContext {
    var duration = 0.0
    var timingFunction: CAMediaTimingFunction?
    static func runAnimationGroup(_ action: (inout Self) -> Void) {
        var context = Self()
        action(&context)
    }
}
enum LockScreenAnimationTimings { static let unlockCollapse = 0.03 }
enum LockScreenLiveActivityOverlay {
    static func collapsedScale(for notchSize: CGSize, isDynamicIslandMode: Bool) -> CGFloat { 0.7 }
}
final class FixtureWindow {
    var alphaValue = 1.0
    var contentView: NSObject? = NSObject()
    var hides = 0
    var closed = false
    func animator() -> Self { self }
    func orderOut(_ sender: Any?) { hides += 1 }
    func close() { closed = true }
}
final class ScreenCaptureVisibilityManager {
    static let shared = ScreenCaptureVisibilityManager()
    var unregistered: FixtureWindow?
    func unregister(_ window: FixtureWindow) { unregistered = window }
}
final class FixtureOverlayModel {
    var opacity = 1.0
    var scale: CGFloat = 1
}

@MainActor final class OverlayFixture {
    var window: FixtureWindow? = FixtureWindow()
    var hideTask: Task<Void, Never>?
    var presentationID = UUID()
    var currentNotchSize: CGSize? = CGSize(width: 100, height: 30)
    var hostingView: NSObject? = NSObject()
    var hasDelegated = true
    var observersActive = true
    let isDynamicIslandMode = false
    let overlayModel = FixtureOverlayModel()
    func timestamp() -> String { "fixture" }
    func removeScreenChangeObservers() { observersActive = false }
}

@main struct LockScreenLiveActivityLifecycleTests {
    @MainActor static func main() async throws {
        let fixture = OverlayFixture()
        let window = fixture.window!
        fixture.hideWithAnimation(presentationID: fixture.presentationID)
        fixture.beginPresentation()
        try await Task.sleep(for: .milliseconds(100))
        precondition(window.hides == 0, "Old hide must not dismiss a new presentation")

        fixture.hideWithAnimation(presentationID: fixture.presentationID)
        fixture.hideImmediately()
        try await Task.sleep(for: .milliseconds(100))
        precondition(window.hides == 1 && window.closed && window.contentView == nil)
        precondition(fixture.window == nil && fixture.hostingView == nil && !fixture.hasDelegated)
        precondition(!fixture.observersActive && fixture.currentNotchSize == nil && fixture.hideTask == nil)
        precondition(ScreenCaptureVisibilityManager.shared.unregistered === window)

        fixture.window = FixtureWindow()
        fixture.currentNotchSize = CGSize(width: 100, height: 30)
        fixture.observersActive = true
        fixture.hideWithAnimation(presentationID: fixture.beginPresentation())
        for _ in 0..<30 where fixture.hideTask != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(fixture.window?.hides == 1 && fixture.currentNotchSize == nil)
        precondition(!fixture.observersActive && fixture.hideTask == nil)
        print("Lock-screen Live Activity lifecycle checks passed")
    }
}
