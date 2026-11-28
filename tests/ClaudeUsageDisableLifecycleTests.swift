import Foundation

@main
enum ClaudeUsageDisableLifecycleTests {
    static func main() {
        let retiredBeforeLaunch = ResumeLease()
        retiredBeforeLaunch.retire()
        var launches = 0
        let blocked: Int? = retiredBeforeLaunch.performIfActive {
            launches += 1
            return launches
        }
        precondition(blocked == nil && launches == 0)

        let inFlight = ResumeLease()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = inFlight.performIfActive { () -> Bool? in
                entered.signal()
                release.wait()
                return true
            }
            finished.signal()
        }
        entered.wait()

        let retired = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            inFlight.retire()
            retired.signal()
        }
        precondition(retired.wait(timeout: .now() + 0.05) == .timedOut)
        release.signal()
        finished.wait()
        retired.wait()
        precondition(!inFlight.isActive)

        // An off/on cycle gets a distinct lease. Retiring the old generation
        // must not prevent the new generation from doing its own launch work.
        let oldGeneration = ResumeLease()
        oldGeneration.retire()
        let newGeneration = ResumeLease()
        precondition(oldGeneration.performIfActive { 1 } == nil)
        precondition(newGeneration.performIfActive { 2 } == 2)

        print("Claude usage resume lease retirement and off/on generation checks passed")
    }
}
