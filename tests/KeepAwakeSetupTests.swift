import Foundation

enum AppFeature {
    case keepAwake

    private static let lock = NSLock()
    private static var available = true

    var isAvailable: Bool { Self.lock.withLock { Self.available } }

    static func setAvailable(_ value: Bool) {
        lock.withLock { available = value }
    }
}

enum Sudoers {
    static let probeStarted = DispatchSemaphore(value: 0)
    static let releaseProbe = DispatchSemaphore(value: 0)
    static var installReplies: [(Bool) -> Void] = []

    static func isConfigured(shouldProceed: () -> Bool) -> Bool {
        precondition(shouldProceed())
        probeStarted.signal()
        precondition(releaseProbe.wait(timeout: .now() + 5) == .success)
        return false
    }

    static func install(shouldProceed: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        precondition(shouldProceed())
        installReplies.append(completion)
    }
}

final class SetupFixture {
    var isTerminating = false
    var clamshellRestorePending = false
    var clamshellPreferred = true
    var clamshellSetupInProgress = false
    var clamshellSetupFailed = false
    var clamshellSetupRequest: BoundedProcessCancellation?
    var passwordlessClamshell = false
    var isActive = true
    var sessionPausedForScreenLock = false
    var enableCount = 0

    func markClamshellSetupFailed() {
        clamshellPreferred = false
        clamshellSetupFailed = true
    }

    func enableClamshell() { enableCount += 1 }
}

@main struct KeepAwakeSetupTests {
    @MainActor static func main() async {
        let fixture = SetupFixture()
        AppFeature.setAvailable(false)
        fixture.prepareClamshellPreference()
        precondition(fixture.clamshellSetupRequest == nil, "Off must reject fresh setup")

        AppFeature.setAvailable(true)
        fixture.prepareClamshellPreference()
        precondition(Sudoers.probeStarted.wait(timeout: .now() + 3) == .success)
        let staleProbe = fixture.clamshellSetupRequest!
        AppFeature.setAvailable(false)
        fixture.cancelClamshellSetup()
        Sudoers.releaseProbe.signal()
        AppFeature.setAvailable(true)

        fixture.prepareClamshellPreference()
        precondition(Sudoers.probeStarted.wait(timeout: .now() + 3) == .success)
        Sudoers.releaseProbe.signal()
        for _ in 0..<30 where Sudoers.installReplies.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(staleProbe.isCancelled)
        precondition(Sudoers.installReplies.count == 1, "Only the new probe may request authorization")

        AppFeature.setAvailable(false)
        fixture.cancelClamshellSetup()
        precondition(!fixture.clamshellSetupInProgress && fixture.clamshellPreferred)
        AppFeature.setAvailable(true)
        fixture.prepareClamshellPreference()
        precondition(Sudoers.probeStarted.wait(timeout: .now() + 3) == .success)
        let current = fixture.clamshellSetupRequest!
        Sudoers.installReplies[0](false)
        Sudoers.releaseProbe.signal()
        for _ in 0..<30 where Sudoers.installReplies.count < 2 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(Sudoers.installReplies.count == 2)
        precondition(fixture.clamshellSetupRequest === current && fixture.clamshellPreferred)
        precondition(!fixture.clamshellSetupFailed && fixture.enableCount == 0)

        Sudoers.installReplies[1](true)
        for _ in 0..<30 where fixture.clamshellSetupInProgress {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(fixture.passwordlessClamshell && fixture.enableCount == 1)
        precondition(fixture.clamshellSetupRequest == nil && !fixture.clamshellSetupInProgress)
        print("Keep Awake setup lifecycle checks passed")
    }
}
