import CoreGraphics
import XCTest
@testable import AnchorUtilities

final class RecorderCacheTests: XCTestCase {
    private func image(width: Int = 64, height: Int = 64) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    func testEvictsLeastRecentlyUsedBitmapBeforeExceedingDecodedByteBudget() throws {
        let picture = try image()
        let cost = picture.bytesPerRow * picture.height
        let cache = RecorderBitmapCache(byteLimit: cost * 2, observesMemoryPressure: false)
        cache.insert(picture, for: "first")
        cache.insert(picture, for: "second")
        XCTAssertNotNil(cache.image(for: "first"))
        cache.insert(picture, for: "third")
        XCTAssertNil(cache.image(for: "second"))
        XCTAssertNotNil(cache.image(for: "first"))
        XCTAssertNotNil(cache.image(for: "third"))
        XCTAssertEqual(cache.retainedBytes, cost * 2)
    }

    func testOversizeBitmapRemainsUsableWithoutProcessWideRetention() throws {
        let picture = try image()
        let cost = picture.bytesPerRow * picture.height
        let cache = RecorderBitmapCache(byteLimit: cost - 1, observesMemoryPressure: false)
        cache.insert(picture, for: "oversize")
        XCTAssertNil(cache.image(for: "oversize"))
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertEqual(picture.width, 64, "Eviction must not invalidate the active render plan's image")
    }

    func testReplacementUsesActualRowStrideAndDoesNotDoubleCount() throws {
        let small = try image(width: 1, height: 10)
        let larger = try image(width: 2, height: 20)
        let cost = larger.bytesPerRow * larger.height
        let cache = RecorderBitmapCache(byteLimit: cost * 2, observesMemoryPressure: false)
        cache.insert(small, for: "edited")
        cache.insert(larger, for: "edited")
        XCTAssertEqual(cache.retainedBytes, cost)
        XCTAssertEqual(cache.image(for: "edited")?.height, 20)
        cache.removeAll()
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertNil(cache.image(for: "edited"))
    }

    func testManyTinySpritesAlsoRespectEntryBudget() throws {
        let picture = try image(width: 1, height: 1)
        let cache = RecorderBitmapCache(byteLimit: 1024 * 1024, entryLimit: 2,
                                        observesMemoryPressure: false)
        for index in 0..<10 { cache.insert(picture, for: String(index)) }
        XCTAssertNil(cache.image(for: "7"))
        XCTAssertNotNil(cache.image(for: "8"))
        XCTAssertNotNil(cache.image(for: "9"))
        XCTAssertEqual(cache.retainedBytes, picture.bytesPerRow * picture.height * 2)
    }

    func testConcurrentExportAndPreviewKeepCacheBounded() throws {
        let picture = try image()
        let budget = picture.bytesPerRow * picture.height * 3
        let cache = RecorderBitmapCache(byteLimit: budget, observesMemoryPressure: false)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            cache.insert(picture, for: String(index % 11))
            _ = cache.image(for: String((index + 1) % 11))
            if index % 9 == 0 { cache.removeAll() }
        }
        XCTAssertLessThanOrEqual(cache.retainedBytes, budget)
        cache.removeAll()
        XCTAssertEqual(cache.retainedBytes, 0)
    }

    func testRecorderSpritesStillReuseRasterizationsAndCanReleaseThem() throws {
        let first = try XCTUnwrap(RecorderCursorSprite.arrow(pixelSize: 56))
        let repeated = try XCTUnwrap(RecorderCursorSprite.arrow(pixelSize: 56))
        XCTAssertTrue(first === repeated)
        RecorderCursorSprite.clearCache()
        let rerendered = try XCTUnwrap(RecorderCursorSprite.arrow(pixelSize: 56))
        XCTAssertFalse(first === rerendered)
        XCTAssertEqual(first.width, rerendered.width)
        XCTAssertEqual(first.height, rerendered.height)
        RecorderCursorSprite.clearCache()
    }
}
