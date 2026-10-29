import XCTest
@testable import AnchorUtilities

final class NativeWindowTilingTests: XCTestCase {
    func testNativeDomainRoundTripAndExternalChanges() {
        let domain = "Anchor.NativeTilingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = NativeWindowTilingPreferences(domain: domain)
        let second = NativeWindowTilingPreferences(domain: domain)
        XCTAssertTrue(first.refresh())
        XCTAssertEqual(first.value(.edges), true)
        for setting in NativeWindowTilingPreference.allCases {
            XCTAssertTrue(first.set(setting, to: false))
            XCTAssertTrue(second.refresh())
            XCTAssertEqual(second.value(setting), false)
            XCTAssertTrue(second.set(setting, to: true))
            XCTAssertTrue(first.refresh())
            XCTAssertEqual(first.value(setting), true)
        }
        defaults.set("unexpected value", forKey: NativeWindowTilingPreference.edges.rawValue)
        defaults.synchronize()
        XCTAssertTrue(first.refresh())
        XCTAssertNil(first.value(.edges), "An unsupported value must never appear as an editable Off switch")
    }
}
