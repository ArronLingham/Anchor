import Foundation

final class SessionActivity {
    static let shared = SessionActivity()
    var ticket: UUID? = UUID()
    func captureActiveSession() -> UUID? { ticket }
    func acceptsSession(_ session: UUID) -> Bool { ticket == session }
}

final class AppVolumeMixer {
    static let shared = AppVolumeMixer()
    var selected: [[String]] = []
    var succeeds = true
    func switchToNextSoundOutput(in uids: [String]) -> Bool {
        selected.append(uids)
        return succeeds
    }
}

final class SwitchFixture {
    static var switcherWanted = true
    let shortcutGate = ClipboardPresentationGate()
    var lastSwitchFailed = false
    var queued: [() -> Void] = []
    func selectedDeviceUIDs() -> [String] { ["fixture-device"] }
    func enqueue(_ operation: @escaping () -> Void) { queued.append(operation) }
    func drain() {
        let operations = queued
        queued.removeAll()
        operations.forEach { $0() }
    }
}

@main
enum SoundOutputSwitcherLifecycleTests {
    static func main() {
        let service = SwitchFixture()
        service.shortcutGate.update(available: true)
        service.scheduleSwitch()
        SwitchFixture.switcherWanted = false
        service.drain()
        precondition(AppVolumeMixer.shared.selected.isEmpty)

        SwitchFixture.switcherWanted = true
        service.scheduleSwitch()
        service.shortcutGate.update(available: false)
        service.shortcutGate.update(available: true)
        service.drain()
        precondition(AppVolumeMixer.shared.selected.isEmpty)

        service.scheduleSwitch()
        SessionActivity.shared.ticket = UUID()
        service.drain()
        precondition(AppVolumeMixer.shared.selected.isEmpty)

        service.scheduleSwitch()
        AppVolumeMixer.shared.succeeds = false
        service.drain()
        precondition(AppVolumeMixer.shared.selected == [["fixture-device"]] && service.lastSwitchFailed)
        print("Sound output switching off, re-registration, session and feedback checks passed")
    }
}
