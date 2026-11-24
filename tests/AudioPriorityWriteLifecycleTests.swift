import Foundation

enum DefaultsKey {
    static let audioPriorityOutputEnabled = "output"
    static let audioPriorityInputEnabled = "input"
}
enum AppFeature {
    case audioPriority
    static var available = true
    var isAvailable: Bool { Self.available }
}
enum UtilityPreferences { static let standard = Preferences() }
final class Preferences {
    var keys = Set([DefaultsKey.audioPriorityOutputEnabled, DefaultsKey.audioPriorityInputEnabled])
    func bool(forKey key: String) -> Bool { keys.contains(key) }
}

final class PriorityFixture {
    var started = true
    let outputWriteGate = ClipboardPresentationGate()
    let inputWriteGate = ClipboardPresentationGate()
}

@main
enum AudioPriorityWriteLifecycleTests {
    static func main() {
        let fixture = PriorityFixture()
        let inputKey = DefaultsKey.audioPriorityInputEnabled
        let outputKey = DefaultsKey.audioPriorityOutputEnabled
        fixture.syncWriteGates()
        let inputWrite = fixture.priorityWriteCheck(fixture.inputWriteGate, key: inputKey)!
        let outputWrite = fixture.priorityWriteCheck(fixture.outputWriteGate, key: outputKey)!
        precondition(inputWrite() && outputWrite())

        UtilityPreferences.standard.keys.remove(inputKey)
        precondition(!inputWrite() && outputWrite())
        fixture.syncWriteGates()
        precondition(fixture.priorityWriteCheck(fixture.inputWriteGate, key: inputKey) == nil)
        UtilityPreferences.standard.keys.insert(inputKey)
        fixture.syncWriteGates()
        precondition(!inputWrite() && outputWrite())
        precondition(fixture.priorityWriteCheck(fixture.inputWriteGate, key: inputKey)?() == true)

        AppFeature.available = false
        precondition(!outputWrite())
        fixture.started = false
        fixture.syncWriteGates()
        AppFeature.available = true
        fixture.started = true
        fixture.syncWriteGates()
        precondition(!outputWrite() && !inputWrite())
        precondition(fixture.priorityWriteCheck(fixture.outputWriteGate, key: outputKey)?() == true)
        print("Audio Priority independent input/output write and stale generation checks passed")
    }
}
