import AVFoundation
import Combine
import Foundation

enum Defaults {
    enum Key { case enableDictation, enableShortcuts, dictationAutoPaste, dictationFeedbackSound, dictationTidyWhitespace }
    struct Change { let newValue: Bool }
    private static var values: [Key: Bool] = [
        .enableDictation: true, .enableShortcuts: true, .dictationAutoPaste: true,
    ]
    private static let changes = PassthroughSubject<(Key, Bool), Never>()
    static subscript(key: Key) -> Bool {
        get { values[key] ?? false }
        set {
            values[key] = newValue
            changes.send((key, newValue))
        }
    }
    static func publisher(_ key: Key, options: [Int]) -> AnyPublisher<Change, Never> {
        changes.filter { $0.0 == key }.map { Change(newValue: $0.1) }.eraseToAnyPublisher()
    }
}

typealias AppleSpeechTranscriber = FixtureBackend

@MainActor
final class FixtureBackend: SpeechTranscribing {
    var holdsPreparation = false
    var preparation: CheckedContinuation<Void, Never>?
    var finishing: CheckedContinuation<String, Never>?
    var update: ((TranscriptUpdate) -> Void)?
    var starts = 0
    var cancels = 0
    var preferredFormat: AVAudioFormat? { get async { nil } }

    func prepare() async throws {
        if holdsPreparation { await withCheckedContinuation { preparation = $0 } }
    }
    func start(onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void) async throws {
        update = onUpdate
        starts += 1
    }
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() async throws -> String { await withCheckedContinuation { finishing = $0 } }
    func cancel() async { cancels += 1 }
}

@MainActor
enum TextInjector {
    static var pasted: [String] = []
    static func insert(_ value: String, shouldPaste: () -> Bool) async throws {
        if shouldPaste() { pasted.append(value) }
    }
}

@MainActor
final class FixturePasteboard {
    enum Contents { case string }
    static let shared = FixturePasteboard()
    var changeCount = 1
    var text = "original"
    func clearContents() { text = ""; changeCount += 1 }
    func setString(_ value: String, forType: Contents) { text = value }
}

@MainActor
enum DeliveryFixture {
    enum InjectionError: Error { case accessibilityNotTrusted }
    static var pendingRestore: Task<Void, Never>?
    static var posted: [String] = []
    static let hasAccessibilityPermission = true
    static func waitForModifiersToClear() async {}
    static func snapshot(of board: FixturePasteboard) -> String { board.text }
    static func ignoreInClipboardHistory(_ count: Int) {}
    static func postPasteKeystroke() throws { posted.append(FixturePasteboard.shared.text) }
    static func restore(_ contents: String, to board: FixturePasteboard) {
        board.clearContents()
        board.setString(contents, forType: .string)
    }
}

@main
enum DictationDisableLifecycleTests {
    @MainActor
    static func main() async throws {
        let preparing = FixtureBackend()
        preparing.holdsPreparation = true
        let listening = FixtureBackend()
        let transcribing = FixtureBackend()
        let current = FixtureBackend()
        var backends = [preparing, listening, transcribing, current]
        let manager = DictationManager(makeBackend: { backends.removeFirst() })

        manager.beginDictation()
        await waitUntil { preparing.preparation != nil }
        Defaults[.enableDictation] = false
        await waitUntil { manager.state == .idle && preparing.cancels == 1 }
        Defaults[.enableDictation] = true
        manager.beginDictation()
        await waitUntil { manager.state == .listening }
        preparing.preparation?.resume()
        precondition(manager.fixtureEngineIsRecording && preparing.starts == 0)

        Defaults[.enableShortcuts] = false
        await waitUntil { manager.state == .idle && listening.cancels == 1 }
        precondition(!manager.fixtureEngineIsRecording)
        Defaults[.enableShortcuts] = true
        manager.beginDictation()
        await waitUntil { manager.state == .listening }
        manager.endDictation()
        await waitUntil { transcribing.finishing != nil }
        precondition(!manager.fixtureEngineIsRecording)
        Defaults[.enableDictation] = false
        await waitUntil { manager.state == .idle && transcribing.cancels == 1 }
        Defaults[.enableDictation] = true
        manager.beginDictation()
        await waitUntil { manager.state == .listening }
        transcribing.update?(TranscriptUpdate(settledText: "retired", volatileText: ""))
        transcribing.finishing?.resume(returning: "retired")

        manager.endDictation()
        await waitUntil { current.finishing != nil }
        current.finishing?.resume(returning: "current")
        await waitUntil { manager.state == .idle }
        precondition(TextInjector.pasted == ["current"] && manager.live.transcript.isEmpty)

        let board = FixturePasteboard.shared
        try await DeliveryFixture.insert("blocked") { false }
        precondition(board.text == "original" && board.changeCount == 1 && DeliveryFixture.posted.isEmpty)
        var checks = 0
        try await DeliveryFixture.insert("cancelled") {
            checks += 1
            return checks == 1
        }
        precondition(board.text == "original" && DeliveryFixture.posted.isEmpty)

        let accepted = Task { try await DeliveryFixture.insert("accepted") }
        await waitUntil { DeliveryFixture.pendingRestore != nil }
        accepted.cancel()
        let next = Task { try await DeliveryFixture.insert("next") }
        await Task.yield()
        precondition(DeliveryFixture.posted == ["accepted"] && board.text == "accepted")
        try await accepted.value
        try await next.value
        precondition(DeliveryFixture.posted == ["accepted", "next"] && board.text == "original")
        print("Dictation cancellation, stale delivery and clipboard restoration checks passed")
    }

    @MainActor
    private static func waitUntil(_ ready: () -> Bool) async {
        for _ in 0..<400 {
            if ready() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Dictation fixture did not reach the expected state")
    }
}
