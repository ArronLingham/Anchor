import AppKit
import XCTest
@testable import AnchorUtilities

final class ClipboardIconMemoryTests: XCTestCase {
    func testHistoryFileIconsKeepOnlyTheDisplayedBitmap() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try Data("Clipboard icon fixture".utf8).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
            ClipboardImageStore.clearMemoryCaches()
        }
        let icon = ClipboardImageStore.fileIcon(atPath: file.path)
        let bitmap = try XCTUnwrap(icon.representations.first as? NSBitmapImageRep)
        let maxPixels = max(16, Int(ceil(20 * ImageThumbnailer.backingScale)))
        XCTAssertLessThanOrEqual(bitmap.pixelsWide, maxPixels)
        XCTAssertLessThanOrEqual(bitmap.pixelsHigh, maxPixels)
        XCTAssertEqual(icon.representations.count, 1,
                       "A small history marker must not retain the Finder icon's full-size representations")
        XCTAssertTrue(icon === ClipboardImageStore.fileIcon(atPath: file.path),
                      "Repeated row renders must reuse the downsampled icon")
    }
}
