import AppKit
import ApplicationServices
import Foundation

final class SessionActivity {
  static let shared = SessionActivity()
  var isActive = true
  func onChange(_ action: @escaping (Bool) -> Void) {}
}
enum SessionActivitySupport {
  static func tapShouldRun(featureWanted: Bool, accessibilityGranted: Bool, sessionIsActive: Bool)
    -> Bool
  { false }
}
final class UtilityWorkspace {
  static let shared = UtilityWorkspace()
  func prepareOwnership() {}
}
enum AppFeature {
  case windowMaximizer
  var isAvailable: Bool { false }
}
enum UtilityPreferences {
  static let standard = UserDefaults(suiteName: "Anchor.maximizer.fixture")!
}
enum DefaultsKey {
  static let windowMaximizeEnabled = "enabled"
  static let windowMaximizeExcludedApps = "excluded"
}
enum Defaults { static func sanitizedBundleIdentifierList(_ list: [String]) -> [String] { list } }
final class EnhancedUserInterfaceSuspension {
  static var suspended = 0
  static func suspend(forAppOf: AXUIElement) -> EnhancedUserInterfaceSuspension? {
    suspended += 1
    return Self()
  }
  func resume() { Self.suspended -= 1 }
}
enum WindowServerTrafficLightHitTest {
  enum Button { case zoom }
  struct Candidate { let pid: pid_t }
  static func candidate(at: CGPoint, button: Button) -> Candidate? { nil }
}
enum AXWindowResolver { static func windowID(for: AXUIElement) -> CGWindowID? { nil } }
@main struct MaximizerTests {
  static func main() {
    let manager = WindowMaximizer.shared
    manager.fixtureBegin()
    manager.fixtureAdvance(0.05)
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline && manager.fixtureRect.width == 200 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    let intermediate = manager.fixtureRect
    precondition(intermediate.width > 200 && intermediate.width < 800)
    manager.stop()
    precondition(!manager.isRunning)
    precondition(manager.fixtureOriginals == 1)
    precondition(EnhancedUserInterfaceSuspension.suspended == 1)
    manager.fixtureAdvance(0.3)
    let end = Date().addingTimeInterval(1)
    while Date() < end && manager.fixtureTimers > 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(manager.fixtureRect.width == 800 && manager.fixtureRect.height == 600)
    precondition(EnhancedUserInterfaceSuspension.suspended == 0)
    precondition(manager.fixtureTimers == 0)
    precondition(manager.fixtureOriginals == 0)
    manager.fixtureBegin()
    manager.stop(finishAcceptedChanges: false)
    precondition(manager.fixtureTimers == 0)
    precondition(manager.fixtureOriginals == 0)
    precondition(EnhancedUserInterfaceSuspension.suspended == 0)
    print("Window Maximizer: interrupted animation finishes, releases suspension and drains timers")
  }
}
