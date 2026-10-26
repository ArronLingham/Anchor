import XCTest
@testable import AnchorUtilities

final class SettingsIntegrationTests: XCTestCase {
    func testNativePagesUseOneHostRoute() {
        let workspace = UtilityWorkspace.shared
        let oldLibrary = workspace.onOpenFeatureLibrary
        let oldIsland = workspace.onOpenIslandSettings
        let oldSettings = workspace.onOpenAnchorSettings
        defer { workspace.onOpenFeatureLibrary = oldLibrary; workspace.onOpenIslandSettings = oldIsland; workspace.onOpenAnchorSettings = oldSettings }
        var libraryVisits = 0, islandVisits = 0, settingsVisits = 0
        workspace.onOpenFeatureLibrary = { libraryVisits += 1 }
        workspace.onOpenIslandSettings = { islandVisits += 1 }
        workspace.onOpenAnchorSettings = { settingsVisits += 1 }
        XCTAssertTrue(workspace.routeNativeSettingsPage(.features))
        XCTAssertTrue(workspace.routeNativeSettingsPage(.features)) // selecting the same row again
        XCTAssertTrue(workspace.routeNativeSettingsPage(.notch))
        XCTAssertTrue(workspace.routeNativeSettingsPage(.notchMascot))
        XCTAssertTrue(workspace.routeNativeSettingsPage(.general))
        XCTAssertFalse(workspace.routeNativeSettingsPage(.general, hasSection: true))
        XCTAssertEqual(settingsVisits, 1)
        XCTAssertEqual(libraryVisits, 2)
        XCTAssertEqual(islandVisits, 2)
    }

    func testImportedRendererCannotStartAnotherIsland() {
        let name = "AnchorSettingsTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: AppFeature.notch.availabilityKey)
        defaults.set(true, forKey: DefaultsKey.notchEnabled)
        XCTAssertFalse(NotchSupport.isEnabled(in: defaults))
        XCTAssertFalse(UtilityWorkspace.shared.features.contains { $0.id.hasPrefix("notch") })
    }

    func testLoginStartupPolicyRespectsUserChoiceAndApproval() {
        XCTAssertEqual(LaunchAtLoginSupport.startupAction(wanted: true, registration: .off, locationIsUnstable: false), .register)
        XCTAssertEqual(LaunchAtLoginSupport.startupAction(wanted: false, registration: .off, locationIsUnstable: false), .none)
        XCTAssertEqual(LaunchAtLoginSupport.startupAction(wanted: true, registration: .needsApproval, locationIsUnstable: false), .none)
        XCTAssertEqual(LaunchAtLoginSupport.startupAction(wanted: false, registration: .enabled, locationIsUnstable: false), .adoptEnabled)
        XCTAssertEqual(LaunchAtLoginSupport.startupAction(wanted: true, registration: .off, locationIsUnstable: true), .none)
    }
}
