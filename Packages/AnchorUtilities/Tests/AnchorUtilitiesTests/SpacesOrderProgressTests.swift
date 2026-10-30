import Combine
import XCTest
@testable import AnchorUtilities

final class SpacesOrderProgressTests: XCTestCase {
    func testProgressTracksLatestQueuedChange() {
        let domain = "Anchor.SpacesProgressTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let firstStarted = expectation(description: "first change began")
        let secondStarted = expectation(description: "replacement change began")
        let visible = expectation(description: "progress shown")
        let finished = expectation(description: "progress hidden after latest change")
        let firstGate = DispatchSemaphore(value: 0)
        let secondGate = DispatchSemaphore(value: 0)
        var reads = 0 // read only on the service's serial queue
        let system = SpacesOrderSystem(read: {
            reads += 1
            if reads == 1 { firstStarted.fulfill(); firstGate.wait() }
            else if reads == 2 { secondStarted.fulfill(); secondGate.wait() }
            return .off
        }, write: { _ in XCTFail("Unexpected system write"); return false },
           restartDock: { XCTFail("Unexpected Dock restart"); return false },
           dockPID: { nil })
        let service = SpacesOrderHold(defaults: defaults, system: system, prepareOwnership: {})
        var wasVisible = false
        let subscription = service.$isApplying.dropFirst().sink { applying in
            if applying && !wasVisible { wasVisible = true; visible.fulfill() }
            if !applying && wasVisible { finished.fulfill() }
        }
        service.syncWithPreferences()
        wait(for: [firstStarted, visible], timeout: 5)
        service.syncWithPreferences()
        firstGate.signal()
        wait(for: [secondStarted], timeout: 5)
        XCTAssertTrue(service.isApplying, "An older completion must not hide newer work")
        secondGate.signal()
        wait(for: [finished], timeout: 5)
        withExtendedLifetime(subscription) {}
    }
}
