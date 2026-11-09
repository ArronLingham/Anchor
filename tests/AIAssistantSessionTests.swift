import Foundation

@MainActor
private final class FakeAssistant {
    var session = AIAssistantSession()
    var enabled = true
    var pending: CheckedContinuation<Void, Never>?
    var sent = 0
    var appliedModels = 0

    func suspendThenFinish(_ token: UInt64, modelList: Bool) async {
        await withCheckedContinuation { pending = $0 }
        guard session.allows(token, enabled: enabled) else { return }
        if modelList { appliedModels += 1 } else { sent += 1 }
    }

    func disable() { enabled = false; session.invalidate() }
    func finish() { pending?.resume(); pending = nil }
}

@main
struct AIAssistantSessionTests {
    @MainActor
    static func main() async {
        let fake = FakeAssistant()
        let first = fake.session.token()
        precondition(!fake.session.allows(first, enabled: false))
        precondition(fake.session.allows(first, enabled: true))

        let capture = Task { await fake.suspendThenFinish(first, modelList: false) }
        while fake.pending == nil { await Task.yield() }
        fake.disable()
        precondition(!fake.session.allows(first, enabled: false))
        fake.enabled = true
        let second = fake.session.token()
        precondition(!fake.session.allows(first, enabled: true))
        fake.finish()
        await capture.value
        precondition(fake.sent == 0, "A capture from before off cannot send after re-enable")

        let listing = Task { await fake.suspendThenFinish(second, modelList: true) }
        while fake.pending == nil { await Task.yield() }
        fake.disable()
        fake.enabled = true
        fake.finish()
        await listing.value
        precondition(fake.appliedModels == 0, "An old model list cannot update the new session")

        let current = fake.session.token()
        precondition(fake.session.allows(current, enabled: true))
        let gate = fake.session
        await Task.detached { gate.invalidate() }.value
        precondition(!gate.allows(current, enabled: true), "An off-main disable invalidates old work")
        print("8/8 AI assistant session checks passed")
    }
}
