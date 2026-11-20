import AppKit

enum DefaultsKey { static let superKeyMappingApplied = "mapped" }
enum UtilityPreferences { static let standard = UserDefaults(suiteName: "AnchorSuperKeyFixture.\(UUID())")! }
final class UtilityWorkspace {
    static let shared = UtilityWorkspace()
    var featureNotice: String?
    func reportFeatureNotice(_ notice: String) { featureNotice = notice }
    func clearFeatureNotice() { featureNotice = nil }
}

final class RecoveryFixture {
    static let mappingRecoveryNotice = "fixture mapping recovery"
    var mappingRecoveryWakeObserver: NSObjectProtocol?
    let notificationCenter = NotificationCenter()
    let lifecycleLock = NSLock()
    var tapThread: Thread?
    var shouldStopTapThread = false
    var isRunning = false
    var cleared = 0
    func clearLeftoverMapping() { cleared += 1 }

    func wake() { notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil) }
}

@main struct SuperKeyRecoveryLifecycleTests {
    static func main() {
        let fixture = RecoveryFixture()
        let workspace = UtilityWorkspace.shared
        let defaults = UtilityPreferences.standard
        defer { defaults.removeObject(forKey: DefaultsKey.superKeyMappingApplied) }
        defaults.set(true, forKey: DefaultsKey.superKeyMappingApplied)
        fixture.updateMappingRecovery(pending: true)
        fixture.updateMappingRecovery(pending: true)
        precondition(workspace.featureNotice == RecoveryFixture.mappingRecoveryNotice)
        fixture.wake()
        precondition(fixture.cleared == 1, "One wake must schedule only one retry")
        fixture.isRunning = true
        fixture.wake()
        precondition(fixture.cleared == 1)
        fixture.isRunning = false
        fixture.tapThread = Thread()
        fixture.wake()
        precondition(fixture.cleared == 1, "A newer start owns the mapping")
        fixture.shouldStopTapThread = true
        fixture.wake()
        precondition(fixture.cleared == 2)
        workspace.reportFeatureNotice("another feature")
        defaults.set(false, forKey: DefaultsKey.superKeyMappingApplied)
        fixture.wake()
        precondition(fixture.cleared == 2 && fixture.mappingRecoveryWakeObserver == nil)
        precondition(workspace.featureNotice == "another feature")
        fixture.updateMappingRecovery(pending: true)
        fixture.updateMappingRecovery(pending: false)
        precondition(workspace.featureNotice == nil && fixture.mappingRecoveryWakeObserver == nil)
        print("Super Key cleanup notice and wake retry checks passed")
    }
}
