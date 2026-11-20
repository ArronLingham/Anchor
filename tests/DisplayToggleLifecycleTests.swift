import AppKit

final class DisplayFixture {
    static var displayControlWanted = true
    var running = false
    var restoringAfterStop = false
    var restartAfterRestoration = false
    let displayToggleGate = ClipboardPresentationGate()
    var screenObserver: NSObjectProtocol?
    var refreshCount = 0

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func screensChanged() {}
    func installWakeObservers() {}
    func refresh() { refreshCount += 1 }
    func syncWithPreferences() { start() }
}

@main struct DisplayToggleLifecycleTests {
    static func main() {
        let fixture = DisplayFixture()
        fixture.start()
        precondition(fixture.running && fixture.refreshCount == 1)
        let stale = fixture.displayToggleGate.capture(currentlyAvailable: true)!
        precondition(fixture.acceptsDisplayToggle(stale))
        DisplayFixture.displayControlWanted = false
        precondition(!fixture.acceptsDisplayToggle(stale), "Worker checks the feature preference before teardown runs")

        // Model the stop boundary before its queued display and gamma restores.
        fixture.running = false
        fixture.displayToggleGate.update(available: false)
        fixture.restoringAfterStop = true
        DisplayFixture.displayControlWanted = true
        fixture.start()
        precondition(fixture.restartAfterRestoration && !fixture.running && fixture.refreshCount == 1)
        precondition(!fixture.acceptsDisplayToggle(stale))
        fixture.finishStopRestoration()
        precondition(fixture.running && fixture.refreshCount == 2 && !fixture.restartAfterRestoration)
        precondition(!fixture.acceptsDisplayToggle(stale), "Old commit and completion must stay rejected after re-enable")

        fixture.running = false
        fixture.restoringAfterStop = true
        fixture.start()
        DisplayFixture.displayControlWanted = false
        fixture.finishStopRestoration()
        precondition(!fixture.running && fixture.refreshCount == 2 && !fixture.restoringAfterStop)
        print("Display toggle generation and restart checks passed")
    }
}
