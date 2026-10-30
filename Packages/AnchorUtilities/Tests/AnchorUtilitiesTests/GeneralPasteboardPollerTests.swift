import XCTest
@testable import AnchorUtilities

final class GeneralPasteboardPollerTests: XCTestCase {
    func testConsumersShareTimerAndCanStopIndependently() {
        let poller = GeneralPasteboardPoller()
        let firstTick = expectation(description: "both consumers receive a tick")
        firstTick.expectedFulfillmentCount = 2
        var firstCount = 0
        var secondCount = 0
        let first = poller.add { firstCount += 1; if firstCount == 1 { firstTick.fulfill() } }
        let second = poller.add { secondCount += 1; if secondCount == 1 { firstTick.fulfill() } }
        wait(for: [firstTick], timeout: 3)

        poller.remove(first)
        let secondTick = expectation(description: "remaining consumer keeps running")
        // Observe the actual repeating timer without making a second subscription.
        let deadline = Date().addingTimeInterval(2)
        while secondCount < 2 && RunLoop.main.run(mode: .default, before: deadline) && Date() < deadline {}
        if secondCount >= 2 { secondTick.fulfill() }
        wait(for: [secondTick], timeout: 0.1)
        XCTAssertEqual(firstCount, 1)

        poller.remove(second)
        let countAtStop = secondCount
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(secondCount, countAtStop)
    }
}
