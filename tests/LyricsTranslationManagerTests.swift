import Combine
import Defaults
import Foundation

struct LyricLine: Identifiable {
    let id = UUID()
    let timestamp: TimeInterval = 1
    let text: String
}
@propertyWrapper final class LyricStream {
    private let subject: CurrentValueSubject<[LyricLine], Never>
    private(set) var observerCount = 0
    init(wrappedValue: [LyricLine]) { subject = CurrentValueSubject(wrappedValue) }
    var wrappedValue: [LyricLine] {
        get { subject.value }
        set { subject.send(newValue) }
    }
    var projectedValue: AnyPublisher<[LyricLine], Never> {
        subject.handleEvents(receiveSubscription: { [weak self] _ in self?.observerCount += 1 },
                             receiveCancel: { [weak self] in self?.observerCount -= 1 })
            .eraseToAnyPublisher()
    }
}
@MainActor final class MusicManager: ObservableObject {
    static let shared = MusicManager()
    @LyricStream var syncedLyrics: [LyricLine] = []
    var lyricObserverCount: Int { _syncedLyrics.observerCount }
    @Published var currentLyricIndex = 0
    var isLiveStream = false
    func seek(to: TimeInterval) {}
}

@main struct LyricsTranslationManagerTests {
    @MainActor static func main() async {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard value() else { fatalError(message) }
        }
        func settle() async { try? await Task.sleep(nanoseconds: 30_000_000) }
        let translator = LyricsTranslator.shared
        let music = MusicManager.shared
        let first = UUID(), second = UUID()
        var firstJobs: [LyricsTranslationCoordinator.Request] = []
        var secondJobs: [LyricsTranslationCoordinator.Request] = []
        await settle()
        music.syncedLyrics = [LyricLine(text: "one")]
        translator.register(first) { if let request = $0 { firstJobs.append(request) } }
        await settle()
        expect(firstJobs.isEmpty, "disabled switches must block work")
        expect(music.lyricObserverCount == 0, "disabled translation must not observe tracks")
        Defaults[.lyricsTranslationEnabled] = true
        await settle()
        expect(firstJobs.isEmpty, "translation switch alone must not bypass lyrics master")
        Defaults[.enableLyrics] = true
        await settle()
        expect(firstJobs.count == 1, "enabling both starts a request")
        expect(music.lyricObserverCount == 1, "visible enabled views share one lyric observer")
        let old = firstJobs.last!
        Defaults[.enableLyrics] = false
        Defaults[.enableLyrics] = true
        translator.apply([(source: "one", target: "old")], request: old, owner: first)
        expect(translator.translations.isEmpty, "old result cannot publish after rapid off/on")
        await settle()
        expect(firstJobs.count == 2, "rapid off/on starts a replacement")
        let replacement = firstJobs.last!
        music.syncedLyrics = [LyricLine(text: "two")]
        translator.apply([(source: "one", target: "wrong")], request: replacement, owner: first)
        expect(translator.translations.isEmpty, "old track cannot publish")
        await settle()
        expect(firstJobs.count == 3, "new track starts a new translation")
        translator.register(second) { if let request = $0 { secondJobs.append(request) } }
        expect(secondJobs.isEmpty, "two views do not duplicate work")
        expect(music.lyricObserverCount == 1, "a second view does not add another lyric observer")
        translator.unregister(first)
        expect(secondJobs.count == 1, "remaining view takes over")
        let current = secondJobs.last!
        translator.apply([(source: "two", target: "deux")], request: current, owner: second)
        expect(translator.translations["two"] == "deux", "current result is displayed")
        Defaults[.lyricsTranslationEnabled] = false
        await settle()
        expect(translator.translations.isEmpty && !translator.isTranslating, "off clears state")
        expect(music.lyricObserverCount == 0, "turning translation off removes the lyric observer")
        Defaults[.lyricsTranslationEnabled] = true
        await settle()
        expect(secondJobs.count == 2, "reenabling translation starts work for the visible view")
        let closing = secondJobs.last!
        translator.unregister(second)
        expect(!translator.isTranslating, "last view leaving stops translation")
        expect(music.lyricObserverCount == 0, "last view leaving removes the lyric observer")
        translator.apply([(source: "two", target: "stale")], request: closing, owner: second)
        expect(translator.translations.isEmpty, "closed view cannot publish")
        translator.register(first) { if let request = $0 { firstJobs.append(request) } }
        expect(firstJobs.count == 4, "reopening lyrics starts translation")
        let emptying = firstJobs.last!
        music.syncedLyrics = []
        translator.apply([(source: "two", target: "stale")], request: emptying, owner: first)
        await settle()
        expect(translator.translations.isEmpty && !translator.isTranslating, "empty lyrics invalidate work")
        translator.unregister(first)
        print("Lyrics translation manager: \(checks) checks passed")
    }
}
