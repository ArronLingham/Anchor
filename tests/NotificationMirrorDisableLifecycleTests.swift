import Foundation

enum Defaults {
    enum Key { case enableNotificationMirroring }
    static var enabled = true
    static subscript(key: Key) -> Bool { enabled }
}

final class FixtureWatch {
    var cancelled = false
    func cancel() { cancelled = true }
}

@MainActor
final class WatchFixture {
    enum State { case running, off }
    var watch: FixtureWatch? = FixtureWatch()
    var watchGeneration = UUID()
    var scheduledRearm: DispatchWorkItem?
    var state = State.running
    var queued: [DispatchWorkItem] = []
    var reads = 0
    var opens = 0
    var canOpen = true
    func drainNewRecords() { reads += 1 }
    func enqueue(_ work: DispatchWorkItem) { queued.append(work) }
    func armWatch() -> Bool {
        disarmWatch()
        opens += 1
        guard canOpen else { return false }
        watch = FixtureWatch()
        return true
    }
}

@main
enum NotificationMirrorDisableLifecycleTests {
    @MainActor
    static func main() {
        let fixture = WatchFixture()
        let original = fixture.watchGeneration
        let oldWatch = fixture.watch!
        fixture.handleWatchEvent(.write, generation: original)
        precondition(fixture.reads == 1)
        fixture.handleWatchEvent(.rename, generation: original)
        fixture.handleWatchEvent(.delete, generation: original)
        fixture.handleWatchEvent(.write, generation: original)
        precondition(fixture.queued.count == 1 && fixture.reads == 1)

        Defaults.enabled = false
        fixture.queued.removeFirst().perform()
        precondition(fixture.opens == 0 && fixture.reads == 1)
        fixture.disarmWatch()
        precondition(oldWatch.cancelled && fixture.scheduledRearm == nil)
        Defaults.enabled = true
        precondition(fixture.armWatch())
        fixture.handleWatchEvent(.write, generation: original)
        fixture.handleWatchEvent(.rename, generation: original)
        precondition(fixture.queued.isEmpty && fixture.reads == 1)

        let current = fixture.watchGeneration
        fixture.handleWatchEvent(.delete, generation: current)
        fixture.queued.removeFirst().perform()
        precondition(fixture.reads == 2 && fixture.opens == 2 && fixture.watch != nil)
        precondition(!fixture.acceptsWatchEvent(current))
        fixture.canOpen = false
        fixture.handleWatchEvent(.revoke, generation: fixture.watchGeneration)
        fixture.queued.removeFirst().perform()
        precondition(fixture.state == .off && fixture.watch == nil && fixture.reads == 2)
        print("Notification Mirror stale events, re-arm and failure checks passed")
    }
}
