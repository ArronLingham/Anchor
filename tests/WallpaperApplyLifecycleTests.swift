import Foundation

enum WallpaperSupport { struct Entry { let imageURL: URL } }
enum FeatureStrings {
    struct Strings {
        let applyFailed = "apply failed"
        let downloadFailed = "download failed"
    }
    static func wallpaper(_ language: String) -> Strings { Strings() }
}
final class L10n {
    static let shared = L10n()
    let language = "en"
}

enum WallpaperStore {
    static let entered = DispatchSemaphore(value: 0)
    static let mayFinish = DispatchSemaphore(value: 0)

    static func waitForEntry() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 4) == .success)
            }
        }
    }

    static func setImageOnAllSpaces(_ url: URL, shouldContinue: () -> Bool) -> Bool {
        guard shouldContinue() else { return false }
        entered.signal()
        return mayFinish.wait(timeout: .now() + 5) == .success
    }
}

final class ApplyFixture {
    private let lock = NSLock()
    private var available = true
    var isAvailable: Bool {
        get { lock.withLock { available } }
        set { lock.withLock { available = newValue } }
    }
    var applyAllDisplays = true
    var applyTask: Task<Void, Never>?
    var applyToken = UUID()
    let applyGenerationLock = NSLock()
    var applyGeneration = UUID()
    var lastError: String?
    var appliedPath: String?
    var isApplying = false
    var isDownloading = false
    var downloads: [URL] = []
    var screenWrites: [URL] = []

    func targetScreens() -> [Int] { [1] }
    func ensureLocalFile(_ url: URL, token: UUID) async -> Bool {
        downloads.append(url)
        return true
    }
    func setDesktopImage(_ url: URL, on screens: [Int], token: UUID) -> Bool {
        screenWrites.append(url)
        return true
    }
}

@main
enum WallpaperApplyLifecycleTests {
    @MainActor
    static func main() async throws {
        let fixture = ApplyFixture()
        let first = WallpaperSupport.Entry(imageURL: URL(fileURLWithPath: "/tmp/first-wallpaper.jpg"))
        let second = WallpaperSupport.Entry(imageURL: URL(fileURLWithPath: "/tmp/second-wallpaper.jpg"))

        fixture.apply(first)
        fixture.isAvailable = false
        fixture.cancelApply()
        await fixture.applyTask?.value
        precondition(fixture.downloads.isEmpty && fixture.screenWrites.isEmpty)

        fixture.isAvailable = true
        fixture.apply(first)
        let firstStoreStarted = await WallpaperStore.waitForEntry()
        precondition(firstStoreStarted)
        fixture.isAvailable = false
        fixture.cancelApply()
        fixture.isAvailable = true
        fixture.applyAllDisplays = false
        fixture.apply(second)
        await Task.yield()
        precondition(fixture.screenWrites == [first.imageURL] && fixture.appliedPath == nil)
        WallpaperStore.mayFinish.signal()
        await fixture.applyTask?.value
        precondition(fixture.screenWrites == [first.imageURL, second.imageURL])
        precondition(fixture.appliedPath == second.imageURL.path && !fixture.isApplying)

        let index = FileManager.default.temporaryDirectory.appendingPathComponent("anchor-wallpaper-index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: index) }
        let baseline = Data([1])
        let prepared = Data([2])
        let external = Data([3])
        try external.write(to: index)
        var reloads = 0
        precondition(!WallpaperStore.commitPreparedIndex(prepared, replacing: baseline, at: index, shouldContinue: { true }) { reloads += 1 })
        let untouched = try Data(contentsOf: index)
        precondition(untouched == external && reloads == 0)
        try baseline.write(to: index)
        precondition(!WallpaperStore.commitPreparedIndex(prepared, replacing: baseline, at: index, shouldContinue: { false }) { reloads += 1 })
        let cancelled = try Data(contentsOf: index)
        precondition(cancelled == baseline && reloads == 0)
        var gateChecks = 0
        precondition(WallpaperStore.commitPreparedIndex(prepared, replacing: baseline, at: index, shouldContinue: {
            gateChecks += 1
            return gateChecks == 1
        }) { reloads += 1 })
        let committed = try Data(contentsOf: index)
        precondition(committed == prepared && reloads == 1 && gateChecks == 1)
        print("Wallpaper apply cancellation, serialization and store commit checks passed")
    }
}
