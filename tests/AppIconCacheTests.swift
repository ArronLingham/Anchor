import AppKit
import Foundation

// The production cache only needs an app URL; the full index has unrelated
// Defaults/search dependencies that are deliberately outside this test.
struct LauncherApp {
    let url: URL
}

private final class RenderProbe: @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    var active = 0
    var peak = 0
    var firstGate: DispatchSemaphore?

    func render(_ app: LauncherApp) -> NSImage {
        lock.lock()
        calls += 1
        let index = calls
        active += 1
        peak = max(peak, active)
        let gate = index == 1 ? firstGate : nil
        lock.unlock()
        if let gate { _ = gate.wait(timeout: .now() + 3) }
        Thread.sleep(forTimeInterval: 0.015)
        let image = NSImage(size: NSSize(width: 64 + index, height: 64))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData, Int32(index), bitmap.bytesPerRow * bitmap.pixelsHigh)
        image.addRepresentation(bitmap)
        lock.lock(); active -= 1; lock.unlock()
        return image
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
}

@main
struct AppIconCacheTests {
    @MainActor
    static func main() async {
        var passed = 0
        var failed = 0
        func check(_ label: String, _ value: Bool) {
            if value { passed += 1 } else { failed += 1; print("FAIL: \(label)") }
        }
        func waitUntil(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            return condition()
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = directory.appendingPathComponent("Example.app")
        try! FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let app = LauncherApp(url: appURL)
        let probe = RenderProbe()
        let cache = AppIconCache(directory: directory.appendingPathComponent("icons"), renderer: probe.render)
        var completions = 0
        var onMain = true
        var firstImage: NSImage?
        cache.warm([app])
        for _ in 0..<40 {
            let hit = cache.icon(for: app) { image in
                onMain = onMain && Thread.isMainThread
                firstImage = image
                completions += 1
            }
            if hit != nil { completions += 1 }
        }
        check("all callers finish", await waitUntil { completions == 40 })
        check("warm and visible misses render once", probe.count == 1)
        check("callbacks run on the main thread", onMain)
        check("subsequent lookup is immediate", cache.icon(for: app, completion: { _ in }) === firstImage)
        cache.warm([app])
        try? await Task.sleep(for: .milliseconds(100))
        check("unchanged warm avoids a second decode", probe.count == 1)

        try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: appURL.path)
        cache.warm([app])
        check("changed application revision replaces its icon", await waitUntil {
            let updated = cache.icon(for: app, completion: { _ in })
            return updated != nil && updated !== firstImage
        })
        check("revision invalidation renders exactly once", probe.count == 2)

        var loaded = 0
        for index in 0..<20 {
            let item = LauncherApp(url: directory.appendingPathComponent("Other-\(index).app"))
            _ = cache.icon(for: item) { _ in loaded += 1 }
        }
        check("all distinct loads finish", await waitUntil { loaded == 20 })
        check("full-index decoding uses at most two workers", probe.maximum <= 2)

        let blockedProbe = RenderProbe()
        let gate = DispatchSemaphore(value: 0)
        blockedProbe.firstGate = gate
        let clearingCache = AppIconCache(directory: directory.appendingPathComponent("clear"), renderer: blockedProbe.render)
        var staleCallbacks = 0
        var freshCallbacks = 0
        _ = clearingCache.icon(for: app) { _ in staleCallbacks += 1 }
        check("clear race begins with an active load", await waitUntil { blockedProbe.count == 1 })
        clearingCache.clear()
        _ = clearingCache.icon(for: app) { _ in freshCallbacks += 1 }
        gate.signal()
        check("post-clear request completes", await waitUntil { freshCallbacks == 1 })
        check("cleared work does not publish a stale icon", staleCallbacks == 0)
        check("post-clear request is a fresh decode", blockedProbe.count == 2)

        print("\(passed) icon cache checks passed; \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
