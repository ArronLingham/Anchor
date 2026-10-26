import XCTest
import CryptoKit
@testable import AnchorUtilities

final class IntegrationTests: XCTestCase {
    func testBundledAgentPricesAreCompleteAndMatchTheReleasedResource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/AnchorUtilities/Resources/agent-prices.json"))
        let prices = try XCTUnwrap(AgentPriceList.decode(data))
        XCTAssertEqual(prices, AgentPriceSource.bundled(), "The actual package resource must resolve")
        XCTAssertFalse(prices.claude.isEmpty)
        XCTAssertFalse(prices.codex.isEmpty)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("UPSTREAM.json"))) as? [String: Any])
        let resources = try XCTUnwrap(manifest["originalResourceSHA256"] as? [String: String])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, resources["Resources/agent-prices.json"])
    }

    func testLibraryUsesTheHostFavoriteChooser() {
        let workspace = UtilityWorkspace.shared
        let previous = workspace.onOpenFeatureLibrary
        defer { workspace.onOpenFeatureLibrary = previous }
        var requests = 0
        workspace.onOpenFeatureLibrary = { requests += 1 }
        workspace.showLibrary()
        XCTAssertEqual(requests, 1, "Dashboard and menu navigation must reach the host library")
    }

    func testSharingDevelopmentOverridesBelongOnlyToAnchorDevelopmentBuilds() {
        let local = "https://127.0.0.1:8765"
        let url = URL(string: local)!
        for id in ["com.arronlingham.Anchor.dev", "com.arronlingham.Anchor", "com.vorssaint.utils.dev"] {
            let isDevelopment = id == "com.arronlingham.Anchor.dev"
            XCTAssertEqual(ScreenshotSharingSupport.endpoint(bundleIdentifier: id, developerOverride: local),
                           isDevelopment ? url : ScreenshotSharingSupport.productionEndpoint)
            XCTAssertEqual(RecordingSharingSupport.endpoint(bundleIdentifier: id, developerOverride: local),
                           isDevelopment ? url : RecordingSharingSupport.productionEndpoint)
        }
        XCTAssertNil(ScreenshotSharingSupport.sanitizedEndpoint("http://127.0.0.1:8765"))
    }

    func testEveryFeatureHasACompleteDestinationAndDescription() {
        let hub = FeatureStrings.hub(.enUS)
        for feature in AppFeature.allCases {
            XCTAssertFalse(feature.hubTitle(.enUS, hub: hub).isEmpty, feature.rawValue)
            XCTAssertFalse(feature.hubDescription(hub).isEmpty, feature.rawValue)
            XCTAssertFalse(feature.symbolName.isEmpty, feature.rawValue)
            _ = feature.settingsDestination
        }
        XCTAssertGreaterThan(AppFeature.allCases.count, 75)
    }

    func testPreferenceDomainCannotOverwriteAnchorOrVorssaint() {
        XCTAssertTrue(UtilityPreferences.domainName.hasSuffix(".utilities"))
        XCTAssertNotEqual(UtilityPreferences.domainName, Bundle.main.bundleIdentifier)
        XCTAssertNotEqual(UtilityPreferences.domainName, "com.vorssaint.utils")
    }

    func testCatalogCanBeAuditedWithoutStartingEngines() throws {
        let features = UtilityWorkspace.shared.features
        XCTAssertEqual(Set(features.map(\.id)), Set(AppFeature.allCases.map(\.rawValue)))
        let rows: [[String: Any]] = features.map { item in
            let feature = AppFeature(rawValue: item.id)!
            return ["id": item.id, "title": item.title, "summary": item.summary,
                    "group": item.group, "settingsPage": String(describing: feature.settingsDestination.page),
                    "permissions": feature.permissions.map(\.rawValue), "enableKeys": feature.enabledKeys,
                    "supported": item.isSupported, "canRun": item.canRun]
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        XCTAssertFalse(data.isEmpty)
        if let output = ProcessInfo.processInfo.environment["ANCHOR_FEATURE_REPORT"] {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    func testFeaturePreferencesStayInTheUtilityStore() {
        _ = UtilityWorkspace.shared
        let store = UtilityPreferences.standard
        let native = Foundation.UserDefaults.standard
        let feature = AppFeature.notchMascot
        let key = DefaultsKey.notchMascotEnabled
        let availability = AppFeature.clipboardHistory.availabilityKey
        let oldUtility = store.object(forKey: key)
        let oldNative = native.object(forKey: key)
        let oldAvailability = store.object(forKey: availability)
        defer {
            if let oldUtility { store.set(oldUtility, forKey: key) } else { store.removeObject(forKey: key) }
            if let oldNative { native.set(oldNative, forKey: key) } else { native.removeObject(forKey: key) }
            if let oldAvailability { store.set(oldAvailability, forKey: availability) } else { store.removeObject(forKey: availability) }
        }
        native.set(false, forKey: key)
        store.set(false, forKey: key)
        XCTAssertEqual(FeatureRuntime.shared.savedPreferences()[key] as? Bool, false)
        feature.enableOnFirstInstall(in: store, savedValues: [:])
        XCTAssertTrue(store.bool(forKey: key))
        XCTAssertFalse(native.bool(forKey: key))
        store.set(false, forKey: key)
        feature.enableOnFirstInstall(in: store, savedValues: FeatureRuntime.shared.savedPreferences())
        XCTAssertFalse(store.bool(forKey: key), "Reinstall preserves the user's saved off choice")
        store.set(true, forKey: availability)
        XCTAssertTrue(AppFeature.clipboardHistory.isAvailable)
    }

    func testAmbiguousQueriesCannotOfferPowerCommands() {
        for query in ["", "s", "screen", "away", "secure", "clock"] {
            XCTAssertFalse(UtilityCommandIntent.allows(id: "action.lockScreen", query: query, title: "Lock Screen"))
        }
        for query in ["lock", "lock screen", "lock mac", "LOCK MAC"] {
            XCTAssertTrue(UtilityCommandIntent.allows(id: "action.lockScreen", query: query, title: "Lock Screen"))
        }
        XCTAssertTrue(UtilityCommandIntent.allows(id: "action.lockScreen", query: "画面をロック", title: "画面をロック"))
        XCTAssertFalse(UtilityCommandIntent.allows(id: "action.displayOff", query: "display", title: "Turn Display Off"))
        XCTAssertTrue(UtilityCommandIntent.allows(id: "action.displayOff", query: "turn off display", title: "Turn Display Off"))
        XCTAssertFalse(UtilityCommandIntent.allows(id: "action.screenSaver", query: "s", title: "Start Screen Saver"))
        XCTAssertTrue(UtilityCommandIntent.allows(id: "action.screenSaver", query: "screen saver", title: "Start Screen Saver"))
        XCTAssertTrue(UtilityCommandIntent.allows(id: "action.screenshot", query: "s", title: "Screenshot"))
    }

    func testPrivilegedIdentifiersBelongToAnchor() {
        XCTAssertEqual(FanControlIdentifiers.teamID, "KLWHJX56T3")
        XCTAssertTrue(FanControlIdentifiers.appBundleID.hasPrefix("com.arronlingham.Anchor"))
        XCTAssertFalse(Sudoers.rulePath.contains("vorssaint"))
        XCTAssertTrue(Sudoers.rulePath.contains("anchor-utilities"))
    }
}
