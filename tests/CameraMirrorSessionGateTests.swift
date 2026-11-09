import Foundation

@main
struct CameraMirrorSessionGateTests {
    static func main() {
        let gate = CameraMirrorSessionGate()
        let first = gate.begin()
        precondition(gate.isCurrent(first), "A visible preview owns its session")

        gate.invalidate()
        precondition(!gate.isCurrent(first), "Disabling invalidates the permission callback")

        let second = gate.begin()
        precondition(gate.isCurrent(second), "A new preview can start")
        precondition(!gate.isCurrent(first), "Re-enabling cannot revive the old callback")

        // Hold the real serial queue so off wins before its queued start runs.
        let queue = DispatchQueue(label: "camera-mirror-fake-session")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let starts = Counter()
        queue.async {
            entered.signal()
            release.wait()
            if gate.isCurrent(second) { starts.increment() }
            finished.signal()
        }
        entered.wait()
        gate.invalidate()
        let third = gate.begin()
        release.signal()
        finished.wait()
        precondition(starts.value == 0, "An old queued start must not run after off/on")
        precondition(gate.isCurrent(third), "Old work must not invalidate the new preview")
        gate.invalidate()
        precondition(!gate.isCurrent(third), "Stopping the last preview releases its token")
        print("7/7 camera mirror lifecycle checks passed")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    }
}
