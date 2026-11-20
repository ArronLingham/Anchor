import Foundation

enum MouseAccelerationRecovery {
    static var pending = true
    static var connected = false
    static var attempts = 0

    static func restorePending(using client: Int? = nil, preservingConnectedEntries: Bool = false) -> Bool {
        attempts += 1
        if connected { pending = false }
        return !pending
    }

    static func hasPendingEntries() -> Bool { pending }
}

final class UtilityWorkspace {
    static let shared = UtilityWorkspace()
    var featureNotice: String?
    func reportFeatureNotice(_ message: String) { featureNotice = message }
    func clearFeatureNotice() { featureNotice = nil }
}

final class RecoveryGuard {
    func stop() -> Bool { true }
}

let kCFAllocatorDefault = 0
func IOHIDEventSystemClientCreateSimpleClient(_ allocator: Int) -> Int { 1 }

final class RecoveryFixture {
    static let recoveryNotice = "Recovery pending"
    var observingRecovery = false
    var featureWanted = false
    var client: Int?
    var sessionIsActive = true
    var systemIsAwake = true
    var reapplyWork: DispatchWorkItem?
    var reapplySchedule = MouseAccelerationReapplySchedule()
    var recoveryGuard: RecoveryGuard?
    var deviceObserver = false
    var linearModeApplications = 0
    var scheduledRetries: [DispatchWorkItem] = []

    func enqueueRetry(after delay: TimeInterval, execute work: DispatchWorkItem) {
        scheduledRetries.append(work)
    }

    func runNextRetry() {
        scheduledRetries.removeFirst().perform()
    }

    func startDeviceObservation() { deviceObserver = true }

    func stopDeviceObservation() {
        reapplyWork?.cancel()
        reapplyWork = nil
        reapplySchedule.cancel()
        deviceObserver = false
    }

    func ensureRecoveryGuard() -> Bool {
        if recoveryGuard == nil { recoveryGuard = RecoveryGuard() }
        return true
    }

    func applyLinearMode() { linearModeApplications += 1 }
}

@main
enum MouseAccelerationRecoveryLifecycleTests {
    static func main() {
        let fixture = RecoveryFixture()
        fixture.observePendingRecovery()
        fixture.runNextRetry()
        precondition(MouseAccelerationRecovery.attempts == 1)
        precondition(fixture.deviceObserver && fixture.recoveryGuard != nil)
        precondition(UtilityWorkspace.shared.featureNotice == RecoveryFixture.recoveryNotice)

        MouseAccelerationRecovery.connected = true
        fixture.scheduleDeviceReapplication()
        fixture.runNextRetry()
        precondition(MouseAccelerationRecovery.attempts == 1)
        fixture.runNextRetry()
        precondition(MouseAccelerationRecovery.attempts == 2)
        precondition(!fixture.observingRecovery && !fixture.deviceObserver && fixture.reapplyWork == nil)
        precondition(fixture.recoveryGuard == nil && UtilityWorkspace.shared.featureNotice == nil)

        MouseAccelerationRecovery.pending = true
        fixture.observePendingRecovery()
        fixture.featureWanted = true
        fixture.runNextRetry()
        precondition(MouseAccelerationRecovery.attempts == 2)
        precondition(MouseAccelerationRecovery.pending)
        UtilityWorkspace.shared.featureNotice = "Unrelated notice"
        fixture.stopRecoveryObservation()
        precondition(!fixture.deviceObserver && fixture.reapplyWork == nil)
        precondition(UtilityWorkspace.shared.featureNotice == "Unrelated notice")
        precondition(fixture.linearModeApplications == 0)

        print("Mouse acceleration disablement recovery checks passed")
    }
}
