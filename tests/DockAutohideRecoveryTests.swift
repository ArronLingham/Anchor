import Foundation

enum UtilityPreferences { static let standard = UserDefaults.standard }
enum DefaultsKey { static let dockPreviewRestoreAutohide = "dockPreviewRestoreAutohide" }

@main struct DockAutohideRecoveryTests {
    static func main() {
        let suite = "Anchor.DockAutohideRecoveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = DefaultsKey.dockPreviewRestoreAutohide
        var current: Bool? = true
        var writes: [Bool] = []
        var restoreSucceeds = true

        func makeHold() -> DockAutohideHold {
            DockAutohideHold(defaults: defaults, readAutohide: { current }) { enabled in
                precondition(defaults.bool(forKey: key), "Record the original setting before writing")
                writes.append(enabled)
                if enabled && !restoreSucceeds { return false }
                current = enabled
                return true
            }
        }

        let hold = makeHold()
        precondition(hold.begin() && current == false && writes == [false])
        precondition(hold.end() && current == true && writes == [false, true])
        precondition(!defaults.bool(forKey: key))

        restoreSucceeds = false
        precondition(hold.begin())
        precondition(!hold.end() && defaults.bool(forKey: key) && !hold.isHolding)
        let countAfterFailedWrite = writes.count
        precondition(!hold.end() && writes.count == countAfterFailedWrite)

        let cold = makeHold()
        precondition(!cold.end(), "An off reading with a leftover marker needs review")
        precondition(!cold.begin() && writes.count == countAfterFailedWrite)
        current = nil
        precondition(!cold.end() && defaults.bool(forKey: key) && writes.count == countAfterFailedWrite)

        current = true
        precondition(cold.end() && !defaults.bool(forKey: key))
        precondition(writes.count == countAfterFailedWrite, "A confirmed original value needs no write")

        restoreSucceeds = true
        precondition(hold.begin())
        current = true // A user already restored their setting while the hold was active.
        let countBeforeEnd = writes.count
        precondition(hold.end() && writes.count == countBeforeEnd)
        print("Dock auto-hide hold, failed restore and cold recovery checks passed")
    }
}
