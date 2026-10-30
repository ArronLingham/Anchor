import Combine
import XCTest
@testable import AnchorUtilities

final class NativeSpacesOrderTests: XCTestCase {
    func testRestartingObservationDuringWriteRefreshesTheActualState() {
        let initial = expectation(description: "initial state loaded")
        let entered = expectation(description: "write started")
        let reloaded = expectation(description: "state reloaded after restarting")
        let gate = DispatchSemaphore(value: 0)
        var rearranges = true
        let service = NativeSpacesOrder(system: NativeSpacesSystem(read: { rearranges }, write: { value in
            entered.fulfill(); gate.wait(); rearranges = value; return true
        }, managed: { false }), preferencePath: "/nonexistent/anchor-test-dock.plist", migrate: {})
        var sawInitial = false
        let observation = service.$fixedOrder.sink { value in
            if value == false && !sawInitial { sawInitial = true; initial.fulfill() }
            if value == true && sawInitial { reloaded.fulfill() }
        }
        service.start()
        defer { service.stop() }
        wait(for: [initial], timeout: 5)
        service.setFixedOrder(true)
        wait(for: [entered], timeout: 5)
        service.stop()
        service.start()
        gate.signal()
        wait(for: [reloaded], timeout: 5)
        XCTAssertEqual(service.fixedOrder, true)
        withExtendedLifetime(observation) {}
    }

    func testWatcherReattachesAfterAtomicPreferenceReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("dock.plist")
        try Data("initial".utf8).write(to: file)
        let initial = expectation(description: "initial read")
        let first = expectation(description: "first replacement observed")
        let second = expectation(description: "second replacement observed")
        let phaseLock = NSLock()
        var phase = 0
        let service = NativeSpacesOrder(system: NativeSpacesSystem(read: {
            phaseLock.lock(); defer { phaseLock.unlock() }
            if phase == 0 { phase = 1; initial.fulfill() }
            else if phase == 2 { phase = 3; first.fulfill() }
            else if phase == 4 { phase = 5; second.fulfill() }
            return false
        }, write: { _ in true }, managed: { false }), preferencePath: file.path, migrate: {})
        service.start()
        defer { service.stop() }
        wait(for: [initial], timeout: 5)
        phaseLock.lock(); phase = 2; phaseLock.unlock()
        try Data("first".utf8).write(to: file, options: .atomic)
        wait(for: [first], timeout: 5)
        phaseLock.lock(); phase = 4; phaseLock.unlock()
        try Data("second".utf8).write(to: file, options: .atomic)
        wait(for: [second], timeout: 5)
    }

    func testSupersededWriteDoesNotHideProgressForNewerChoice() {
        let firstStarted = expectation(description: "first write started")
        let secondStarted = expectation(description: "second write started")
        let pending = expectation(description: "progress shown")
        let done = expectation(description: "latest write settled")
        let firstGate = DispatchSemaphore(value: 0)
        let secondGate = DispatchSemaphore(value: 0)
        var rearranges = true
        var writes = 0 // only accessed on the service's serial queue
        let service = NativeSpacesOrder(system: NativeSpacesSystem(read: { rearranges }, write: { value in
            writes += 1
            if writes == 1 { firstStarted.fulfill(); firstGate.wait() }
            else { secondStarted.fulfill(); secondGate.wait() }
            rearranges = value
            return true
        }, managed: { false }))
        var wasPending = false
        let observation = service.$isApplying.dropFirst().sink { active in
            if active && !wasPending { wasPending = true; pending.fulfill() }
            if !active && wasPending { done.fulfill() }
        }
        service.setFixedOrder(true)
        wait(for: [firstStarted, pending], timeout: 5)
        service.setFixedOrder(false)
        firstGate.signal()
        wait(for: [secondStarted], timeout: 5)
        XCTAssertTrue(service.isApplying)
        secondGate.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(service.fixedOrder, false)
        withExtendedLifetime(observation) {}
    }

    func testWritePublishesNativeReadbackAndProgress() {
        let entered = expectation(description: "write started")
        let pending = expectation(description: "progress shown")
        let done = expectation(description: "actual state published")
        let gate = DispatchSemaphore(value: 0)
        var rearranges = true // accessed on the service's serial queue
        let service = NativeSpacesOrder(system: NativeSpacesSystem(
            read: { rearranges },
            write: { value in entered.fulfill(); gate.wait(); rearranges = value; return true },
            managed: { false }))
        var observedPending = false
        let observation = service.$isApplying.dropFirst().sink { active in
            if active && !observedPending { observedPending = true; pending.fulfill() }
            if !active && observedPending { done.fulfill() }
        }
        service.setFixedOrder(true)
        wait(for: [entered, pending], timeout: 5)
        gate.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(service.fixedOrder, true)
        XCTAssertNil(service.error)
        withExtendedLifetime(observation) {}
    }

    func testFailedWriteKeepsActualStateAndReportsFailure() {
        let done = expectation(description: "failed write settled")
        let service = NativeSpacesOrder(system: NativeSpacesSystem(
            read: { true }, write: { _ in false }, managed: { false }))
        let observation = service.$error.dropFirst().sink { if $0 != nil { done.fulfill() } }
        service.setFixedOrder(true)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(service.fixedOrder, false)
        XCTAssertFalse(service.isApplying)
        withExtendedLifetime(observation) {}
    }

    func testLegacyJournalIsClearedOnlyAfterNativeChoiceIsApplied() {
        let domain = "Anchor.SpacesMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("on", forKey: DefaultsKey.spacesOrderRestore)
        defaults.set("pending", forKey: DefaultsKey.spacesOrderRestartPending)
        XCTAssertFalse(LegacySpacesOrderRecovery.adopt(defaults: defaults, read: { false }, write: { _ in false }))
        XCTAssertNotNil(defaults.object(forKey: DefaultsKey.spacesOrderRestore))
        var applied: Bool?
        XCTAssertTrue(LegacySpacesOrderRecovery.adopt(defaults: defaults, read: { false }, write: { applied = $0; return true }))
        XCTAssertEqual(applied, false)
        XCTAssertNil(defaults.object(forKey: DefaultsKey.spacesOrderRestore))
        XCTAssertNil(defaults.object(forKey: DefaultsKey.spacesOrderRestartPending))
    }

    func testLegacySwitchIsNotExportedAsANewSourceOfTruth() {
        XCTAssertFalse(SettingsBackupSupport.exportKeys().contains(DefaultsKey.spacesOrderEnabled))
        XCTAssertTrue(AppFeature.spacesOrder.enabledKeys.isEmpty)
    }
}
