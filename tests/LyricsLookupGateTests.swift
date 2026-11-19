import Foundation

@main
struct LyricsLookupGateTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError(message) }
        }

        let gate = LyricsLookupGate(enabled: false)
        expect(!gate.permitsLookup(currentlyEnabled: false), "disabled startup cannot use lyrics")
        expect(gate.begin(currentlyEnabled: false) == nil, "disabled startup cannot start a request")
        expect(gate.begin(currentlyEnabled: true) == nil, "a preference value alone cannot bypass a pending notification")
        let onEpoch = gate.update(enabled: true)
        expect(gate.acceptsEpoch(onEpoch, currentlyEnabled: true), "current preference notification is accepted")
        let first = gate.begin(currentlyEnabled: true)!
        expect(gate.accepts(first, currentlyEnabled: true), "enabled request is valid")
        expect(gate.update(enabled: true) == onEpoch, "duplicate enabled notification retains its epoch")
        expect(gate.accepts(first, currentlyEnabled: true), "duplicate notification does not cancel valid work")
        expect(!gate.accepts(first, currentlyEnabled: false), "off preference rejects a request immediately")

        let offEpoch = gate.update(enabled: false)
        expect(!gate.accepts(first, currentlyEnabled: false), "disable invalidates in-flight response")
        expect(!gate.finish(first, currentlyEnabled: false), "disabled response cannot complete")
        let newEpoch = gate.update(enabled: true)
        expect(!gate.acceptsEpoch(offEpoch, currentlyEnabled: true), "queued off notification cannot override re-enable")
        expect(gate.acceptsEpoch(newEpoch, currentlyEnabled: true), "latest on notification is accepted")
        let second = gate.begin(currentlyEnabled: true)!
        expect(!gate.finish(first, currentlyEnabled: true), "old same-track response cannot finish a new request")
        expect(gate.accepts(second, currentlyEnabled: true), "old completion leaves replacement valid")
        let third = gate.begin(currentlyEnabled: true)!
        expect(!gate.accepts(second, currentlyEnabled: true), "replacement invalidates previous request")
        expect(!gate.finish(second, currentlyEnabled: true), "old failure cannot clear replacement")
        expect(gate.finish(third, currentlyEnabled: true), "current response completes")
        expect(!gate.finish(third, currentlyEnabled: true), "response completes only once")
        let fourth = gate.begin(currentlyEnabled: true)!
        gate.cancel()
        expect(!gate.accepts(fourth, currentlyEnabled: true), "track change cancels old request")
        expect(gate.begin(currentlyEnabled: false) == nil, "off preference blocks a new track before notification")
        print("Lyrics lookup gate: \(checks) checks passed")
    }
}
