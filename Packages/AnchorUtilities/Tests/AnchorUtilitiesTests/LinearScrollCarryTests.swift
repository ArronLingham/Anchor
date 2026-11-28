import Foundation
import XCTest
@testable import AnchorUtilities

final class LinearScrollCarryTests: XCTestCase {
    func testRapidOffOnRetiresBothAxesWithoutInputOrTapTeardown() throws {
        let suite = "AnchorLinearScrollTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let key = DefaultsKey.linearScrollEnabled
        let carry = LinearScrollCarry()
        let observer = LinearScrollPreferenceObserver(defaults: preferences, key: key, onDisable: carry.reset)
        let fraction = ScrollWheelAxisDelta(line: 0, point: 0, fixedPoint: 0.6)

        func event(_ generation: UInt64) -> (ScrollWheelAxisDelta, ScrollWheelAxisDelta)? {
            carry.reduce(vertical: fraction, horizontal: fraction, isContinuous: false,
                         linesPerNotch: 1, generation: generation)
        }

        withExtendedLifetime(observer) {
            preferences.set(true, forKey: key)
            let generation = carry.generation
            XCTAssertEqual(event(generation)?.0.line, 0)
            preferences.set(false, forKey: key)
            preferences.set(true, forKey: key)
            XCTAssertNil(event(generation))
            let reenabled = carry.generation
            let first = event(reenabled)
            XCTAssertEqual(first?.0.line, 0)
            XCTAssertEqual(first?.1.line, 0)
            let second = event(reenabled)
            XCTAssertEqual(second?.0.line, 1)
            XCTAssertEqual(second?.1.line, 1)
        }
    }
}
