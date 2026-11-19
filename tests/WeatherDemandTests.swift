import Foundation

@main
struct WeatherDemandTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError(message) }
        }

        var state = WeatherDemandState()
        let launcher = UUID()
        check(!state.hasDemand, "starts without a weather consumer")
        let firstLock = state.beginLock()
        let firstFetch = state.fetchGeneration
        check(state.acceptsLock(firstLock, enabled: true, locked: true), "lock can present")
        check(state.acceptsFetch(firstFetch), "lock can fetch")
        state.addLauncher(launcher)
        state.addLauncher(launcher)
        check(state.launchers.count == 1, "duplicate appearances do not leak a lease")
        check(state.hasUsableDemand(lockAllowed: false, launcherEnabled: true), "enabled launcher is a consumer")
        check(!state.hasUsableDemand(lockAllowed: false, launcherEnabled: false), "disabled controls do not use stale leases")
        check(state.hasUsableDemand(lockAllowed: true, launcherEnabled: false), "lock retains work while launcher is off")
        state.endLock()
        check(!state.acceptsLock(firstLock, enabled: false, locked: true), "off rejects old presentation")
        check(state.acceptsFetch(firstFetch), "launcher keeps the shared fetch alive")
        let secondLock = state.beginLock()
        check(!state.acceptsLock(firstLock, enabled: true, locked: true), "off/on does not revive old presentation")
        check(state.acceptsLock(secondLock, enabled: true, locked: true), "new lock can present")
        check(!state.acceptsLock(secondLock, enabled: true, locked: false), "unlock rejects presentation")
        state.removeLauncher(launcher)
        check(state.acceptsFetch(firstFetch), "lock keeps the fetch alive after launcher closes")
        state.endLock()
        check(!state.hasDemand && !state.acceptsFetch(firstFetch), "last owner invalidates late fetch")
        state.addLauncher(launcher)
        let nextFetch = state.fetchGeneration
        check(nextFetch != firstFetch && state.acceptsFetch(nextFetch), "new owner gets a new fetch generation")
        state.invalidateFetch()
        check(!state.acceptsFetch(nextFetch), "configuration change invalidates old result")
        let updated = state.fetchGeneration
        state.removeLauncher(UUID())
        check(state.acceptsFetch(updated), "unrelated removal preserves a live owner")
        state.removeLauncher(launcher)
        check(!state.acceptsFetch(updated), "closing last launcher invalidates result")

        let epoch = WeatherSettingEpoch()
        let beforeOff = epoch.current()
        epoch.invalidate()
        let beforeOn = epoch.current()
        epoch.invalidate()
        check(!epoch.accepts(beforeOff) && !epoch.accepts(beforeOn), "rapid preference changes reject queued work")
        check(epoch.accepts(epoch.current()), "latest preference epoch is accepted")

        // Simulate a weather response held by a fake provider while ownership
        // changes. No real lock, location permission or network is used.
        var shared = WeatherDemandState()
        let liveLauncher = UUID()
        let oldLock = shared.beginLock()
        let pendingFetch = shared.fetchGeneration
        shared.addLauncher(liveLauncher)
        shared.endLock()
        var launcherUpdates = 0, lockPresentations = 0
        if shared.acceptsFetch(pendingFetch) {
            launcherUpdates += 1
            if shared.acceptsLock(oldLock, enabled: false, locked: true) { lockPresentations += 1 }
        }
        check(launcherUpdates == 1 && lockPresentations == 0,
              "a disabled lock widget cannot reappear while the launcher gets its result")
        shared.removeLauncher(liveLauncher)
        if shared.acceptsFetch(pendingFetch) { launcherUpdates += 1 }
        check(launcherUpdates == 1, "a result after the last consumer leaves is discarded")
        let restoredLock = shared.beginLock()
        check(!shared.acceptsLock(oldLock, enabled: true, locked: true)
              && shared.acceptsLock(restoredLock, enabled: true, locked: true),
              "a new lock session does not accept the previous session's presentation")
        print("\(checks)/\(checks) weather demand checks passed")
    }
}
