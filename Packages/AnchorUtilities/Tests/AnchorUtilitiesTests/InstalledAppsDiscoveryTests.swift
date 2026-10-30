import Foundation
import XCTest
@testable import AnchorUtilities

final class InstalledAppsDiscoveryTests: XCTestCase {
    func testFolderWalkIncludesNestedHiddenAndLinkedAppsWithoutEnteringBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func makeApp(_ path: String) throws -> URL {
            let app = root.appendingPathComponent(path, isDirectory: true)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "test.example.\(UUID().uuidString)",
                "CFBundlePackageType": "APPL"
            ], format: .xml, options: 0)
            try info.write(to: contents.appendingPathComponent("Info.plist"))
            return app
        }

        let regular = try makeApp("Normal.app")
        let nested = try makeApp("Vendor/Nested.app")
        let hidden = try makeApp(".hidden/Hidden.app")
        _ = try makeApp("Normal.app/Contents/Helpers/Inner.app")
        let link = root.appendingPathComponent("Alias.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: regular)
        var found: [URL] = []
        InstalledApps.forEachApplication(in: [root]) { found.append($0.standardizedFileURL) }
        XCTAssertEqual(Set(found), Set([regular, nested, hidden, link].map(\.standardizedFileURL)))
    }

    func testSpotlightAndFolderResultsAreFilteredAndDeduplicatedTogether() {
        let home = "/Users/test"
        let included = home + "/Apps/Editor.app"
        let paths = InstalledApps.applicationScanPaths(
            folderPaths: [included],
            spotlightPaths: [included, home + "/.hidden/Hidden.app", home + "/Library/Build.app",
                             home + "/one/two/three/Deep.app", home + "/Apps/Editor.app/Contents/Other.app"],
            homeDirectory: home)
        XCTAssertEqual(paths, [included])
    }
}
