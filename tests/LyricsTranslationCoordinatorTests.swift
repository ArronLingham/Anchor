import Foundation

@main
struct LyricsTranslationCoordinatorTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError(message) }
        }
        let gate = LyricsLookupGate(enabled: false)
        let coordinator = LyricsTranslationCoordinator(gate: gate)
        let first = UUID(), second = UUID()
        var firstRequests: [LyricsTranslationCoordinator.Request] = []
        var secondRequests: [LyricsTranslationCoordinator.Request] = []
        var cancelled = 0, cleared = 0
        var translating = false
        coordinator.clear = { cleared += 1 }
        coordinator.setTranslating = { translating = $0 }
        let handler1: LyricsTranslationCoordinator.Handler = { request in
            if let request { firstRequests.append(request) } else { cancelled += 1 }
        }
        let handler2: LyricsTranslationCoordinator.Handler = { request in
            if let request { secondRequests.append(request) } else { cancelled += 1 }
        }
        coordinator.register(first, handler: handler1, enabled: false, lines: ["one"])
        expect(firstRequests.isEmpty && !translating, "disabled startup must not translate")
        coordinator.reconcile(enabled: true, lines: ["one"])
        expect(firstRequests.count == 1 && translating, "visible consumer starts translation")
        let original = firstRequests.last!
        coordinator.register(second, handler: handler2, enabled: true, lines: ["one"])
        expect(secondRequests.isEmpty, "second view does not duplicate ongoing work")
        coordinator.unregister(first, enabled: true, lines: ["one"])
        expect(secondRequests.count == 1 && translating, "remaining view takes over")
        let handedOff = secondRequests.last!
        expect(!coordinator.finish(original, owner: first, enabled: true, lines: ["one"], success: true), "departed view cannot publish")
        expect(coordinator.accepts(handedOff, owner: second, enabled: true, lines: ["one"]), "handoff remains valid")
        gate.update(enabled: false)
        expect(!coordinator.accepts(handedOff, owner: second, enabled: false, lines: ["one"]), "off invalidates before UI processing")
        gate.update(enabled: true)
        expect(!coordinator.finish(handedOff, owner: second, enabled: true, lines: ["one"], success: true), "rapid off/on cannot revive request")
        coordinator.reconcile(enabled: true, lines: ["one"])
        expect(secondRequests.count == 2 && cancelled == 1, "rapid off/on cancels and starts a fresh request")
        let retry = secondRequests.last!
        gate.cancel()
        coordinator.reconcile(enabled: true, lines: ["two"])
        expect(!coordinator.finish(retry, owner: second, enabled: true, lines: ["two"], success: true), "old track cannot publish")
        expect(secondRequests.count == 3, "new track starts a new request")
        let next = secondRequests.last!
        expect(!coordinator.accepts(next, owner: second, enabled: true, lines: []), "empty live lyrics reject a response")
        expect(coordinator.finish(next, owner: second, enabled: true, lines: ["two"], success: true), "current result can complete")
        expect(!translating, "completion clears translating state")
        coordinator.reconcile(enabled: true, lines: ["two"])
        expect(secondRequests.count == 3, "completed lyrics are not translated again")
        coordinator.reconcile(enabled: false, lines: ["two"])
        expect(cleared >= 3 && !translating, "disable clears translations")
        coordinator.reconcile(enabled: true, lines: [])
        expect(secondRequests.count == 3, "empty lyrics do not start work")
        coordinator.unregister(second, enabled: true, lines: ["three"])
        expect(secondRequests.count == 3 && !translating, "last view leaving does not start work")
        coordinator.register(first, handler: handler1, enabled: true, lines: ["three"])
        expect(firstRequests.count == 2 && translating, "new view resumes when needed")
        coordinator.unregister(first, enabled: true, lines: ["three"])
        expect(!translating, "last view leaving releases ongoing work")
        print("Lyrics translation coordinator: \(checks) checks passed")
    }
}
