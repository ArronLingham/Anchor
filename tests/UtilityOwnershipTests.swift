import Foundation

@main struct UtilityOwnershipTests {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ name: String) {
            checks += 1
            precondition(condition, name)
        }
        let controls = ["sideButtons": ["navigation"], "gestures": ["navigation"], "keys": ["debounce"]]
        for navigation in [true, false] {
            for debounce in [true, false] {
                let original = ["navigation": navigation, "debounce": debounce]
                var state = UtilityOwnership(paused: [:])
                var current = original
                let writes = state.reconcile(owners: ["sideButtons", "keys"], controls: controls, current: current)
                current.merge(writes) { _, new in new }
                expect(current == ["navigation": false, "debounce": false], "exclusive input ownership")
                expect(state.paused == original, "exact choices preserved")
                let repeated = state.reconcile(owners: ["sideButtons", "keys"], controls: controls, current: current)
                expect(repeated.isEmpty && state.paused == original, "repeated sync cannot replace saved choices")
                current.merge(state.reconcile(owners: ["sideButtons", "gestures"], controls: controls, current: current)) { _, new in new }
                expect(current["debounce"] == debounce && current["navigation"] == false, "only released control restores")
                current.merge(state.reconcile(owners: ["gestures"], controls: controls, current: current)) { _, new in new }
                expect(current["navigation"] == false, "second owner keeps control paused")
                current.merge(state.reconcile(owners: [], controls: controls, current: current)) { _, new in new }
                expect(current == original && state.paused.isEmpty, "last owner restores original choices")
                expect(state.reconcile(owners: ["unknown"], controls: controls, current: current).isEmpty,
                       "unknown features cannot change controls")
            }
        }
        var recovered = UtilityOwnership(paused: ["navigation": true])
        expect(recovered.reconcile(owners: [], controls: controls, current: ["navigation": false]) == ["navigation": true],
               "recover saved choice after interrupted session")

        let clipboardControls = ["clipboardHistory": ["history"], "clipboardAutoClearDelay": ["delay"]]
        var clipboard = UtilityOwnership(paused: [:])
        var choices = ["history": true, "delay": true]
        choices.merge(clipboard.reconcile(owners: ["clipboardHistory"], controls: clipboardControls, current: choices)) { _, new in new }
        expect(choices == ["history": false, "delay": true], "history handover preserves independent native auto-clear")
        choices.merge(clipboard.reconcile(owners: ["clipboardHistory", "clipboardAutoClearDelay"], controls: clipboardControls, current: choices)) { _, new in new }
        expect(choices == ["history": false, "delay": false], "utility delay claims only the overlapping timer")
        choices.merge(clipboard.reconcile(owners: ["clipboardHistory"], controls: clipboardControls, current: choices)) { _, new in new }
        expect(choices == ["history": false, "delay": true], "releasing delay restores native timer without changing history")
        choices.merge(clipboard.reconcile(owners: [], controls: clipboardControls, current: choices)) { _, new in new }
        expect(choices == ["history": true, "delay": true], "releasing history restores its saved setting")
        print("\(checks)/\(checks) utility ownership checks passed")
    }
}
