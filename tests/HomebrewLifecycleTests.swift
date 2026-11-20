import Foundation

enum AppFeature: Hashable {
  case homebrew, appUpdates, uninstaller
  static var enabled: Set<Self> = [.homebrew]
  var isAvailable: Bool { Self.enabled.contains(self) }
}
enum HomebrewEnvironment { static let forBrew = ProcessInfo.processInfo.environment }
enum AppleScriptRunner {
  static func run(_ source: String) -> (ok: Bool, output: String) {
    fatalError("Unexpected automation")
  }
}

@main struct HomebrewLifecycleTests {
  @MainActor static func main() async throws {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
      checks += 1
      precondition(value(), message)
    }
    func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }
    let manager = HomebrewManager.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var completed = 0
    manager.fixtureRun(
      HomebrewCommand(executable: "/bin/sh", arguments: ["-c", "sleep 0.2; printf complete"])
    ) { status, _ in if status == 0 { completed += 1 } }
    AppFeature.enabled = [.appUpdates]
    FeatureServicePool.shared.releaseUnused()
    for _ in 0..<30 {
      if completed == 1 { break }
      await settle()
    }
    check(completed == 1, "remaining shared consumer keeps its read")
    let marker = root.appendingPathComponent("unexpected")
    manager.fixtureRun(HomebrewCommand(executable: "/bin/sleep", arguments: ["30"])) { _, _ in
      completed += 100
    }
    manager.fixtureRun(HomebrewCommand(executable: "/usr/bin/touch", arguments: [marker.path])) {
      _, _ in completed += 100
    }
    await settle()
    AppFeature.enabled = []
    FeatureServicePool.shared.releaseUnused()
    AppFeature.enabled = [.homebrew]
    let again = HomebrewManager.shared
    check(again === manager, "retained view can reuse the released manager")
    again.fixtureRun(HomebrewCommand(executable: "/usr/bin/true", arguments: [])) { status, _ in
      if status == 0 { completed += 1 }
    }
    for _ in 0..<30 {
      if completed == 2 { break }
      await settle()
    }
    check(completed == 2, "stale completions do not update the new enable period")
    check(
      !FileManager.default.fileExists(atPath: marker.path),
      "cancelled queued command does not launch")
    let fixture = root.appendingPathComponent("brew-fixture")
    let started = root.appendingPathComponent("started")
    let released = root.appendingPathComponent("released")
    let body =
      "#!/bin/sh\n/usr/bin/touch '\(started.path)'\nwhile [ ! -e '\(released.path)' ]; do /bin/sleep 0.05; done\nexit 0\n"
    try body.write(to: fixture, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
    var retries = 0
    manager.fixtureTrust(brewPath: fixture.path) { retries += 1 }
    for _ in 0..<30 {
      if FileManager.default.fileExists(atPath: started.path) { break }
      await settle()
    }
    check(FileManager.default.fileExists(atPath: started.path), "fixture trust command started")
    AppFeature.enabled = []
    FeatureServicePool.shared.releaseUnused()
    check(manager.isTrustingTap, "accepted trust remains alive through disable")
    AppFeature.enabled = [.homebrew]
    try Data().write(to: released)
    for _ in 0..<30 {
      if !manager.isTrustingTap { break }
      await settle()
    }
    check(!manager.isTrustingTap, "accepted trust reports completion")
    check(retries == 0, "off/on invalidates the old trust retry")
    let ownershipStarted = root.appendingPathComponent("ownership-started")
    let ownershipReleased = root.appendingPathComponent("ownership-released")
    let ownershipBody =
      "#!/bin/sh\n/usr/bin/touch '\(ownershipStarted.path)'\nwhile [ ! -e '\(ownershipReleased.path)' ]; do /bin/sleep 0.05; done\nprintf '{}'\n"
    try ownershipBody.write(to: fixture, atomically: true, encoding: .utf8)
    manager.fixtureBrewPath(fixture.path)
    var oldOwnership = 0
    var newOwnership = 0
    let appURL = root.appendingPathComponent("Fixture.app")
    manager.packageManagingApplication(at: appURL) { _ in oldOwnership += 1 }
    for _ in 0..<30 {
      if FileManager.default.fileExists(atPath: ownershipStarted.path) { break }
      await settle()
    }
    check(FileManager.default.fileExists(atPath: ownershipStarted.path), "ownership read starts")
    AppFeature.enabled = []
    FeatureServicePool.shared.releaseUnused()
    check(oldOwnership == 1, "last-owner release resolves the abandoned ownership request")
    AppFeature.enabled = [.uninstaller]
    _ = HomebrewManager.shared
    manager.packageManagingApplication(at: appURL) { _ in newOwnership += 1 }
    try Data().write(to: ownershipReleased)
    for _ in 0..<30 {
      if newOwnership > 0 { break }
      await settle()
    }
    check(
      newOwnership == 1 && oldOwnership == 1,
      "old completion cannot consume a replacement ownership callback")
    print("Homebrew manager: \(checks) lifecycle checks passed")
  }
}
enum MetricFormat { static let locale = Locale(identifier: "en_US_POSIX") }
