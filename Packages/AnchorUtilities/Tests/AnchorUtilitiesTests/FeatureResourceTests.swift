import Foundation
import XCTest
@testable import AnchorUtilities

final class FeatureResourceTests: XCTestCase {
    private final class Engine {
        var memory = Data(count: 4 * 1024 * 1024)
        var running = true
    }

    func testColdClipboardHistoryStaysUnloadedForAutoClearAndShortcutCapture() throws {
        guard ClipboardHistoryService.existing == nil, ShelfService.existing == nil, AppSwitcher.existing == nil,
              SoundOutputSwitcher.existing == nil, WindowLayoutService.existing == nil else {
            throw XCTSkip("This process already loaded a service; run this test on its own for the cold-start check.")
        }
        let defaults = UtilityPreferences.standard
        let keys = AppFeature.allCases.map(\.availabilityKey) + [
            DefaultsKey.clipboardHistoryEnabled, DefaultsKey.clipboardAutoClearOnDelay,
            DefaultsKey.clipboardAutoClearOnSleep, DefaultsKey.clipboardAutoClearOnDisplaySleep,
            DefaultsKey.clipboardAutoClearOnScreenLock
        ]
        let old = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            ShortcutCapture.end()
            defaults.set(false, forKey: AppFeature.clipboardHistory.availabilityKey)
            ClipboardAutoClearService.shared.syncWithPreferences()
            for (key, value) in old {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for feature in AppFeature.allCases { defaults.set(false, forKey: feature.availabilityKey) }
        for key in keys.suffix(5) { defaults.set(false, forKey: key) }
        defaults.set(true, forKey: AppFeature.clipboardHistory.availabilityKey)
        defaults.set(true, forKey: DefaultsKey.clipboardAutoClearOnSleep)

        FeatureRuntime.shared.sync([.clipboardHistory])
        XCTAssertNil(ClipboardHistoryService.existing, "An installed auto-clear tool must not load disabled history")
        ShortcutCapture.begin()
        ShortcutCapture.end()
        XCTAssertNil(ClipboardHistoryService.existing, "Recording a shortcut must not load disabled history")
        XCTAssertNil(ShelfService.existing, "Recording a shortcut must not restore a disabled shelf")
        XCTAssertNil(AppSwitcher.existing, "Recording a shortcut must not load the disabled switcher")
        XCTAssertNil(SoundOutputSwitcher.existing, "Recording a shortcut must not load the output switcher")
        XCTAssertNil(WindowLayoutService.existing, "Recording a shortcut must not load window layout")
    }

    func testSwitcherCreatedDuringShortcutCaptureRemainsSuspended() {
        let defaults = UtilityPreferences.standard
        let old = AppFeature.allCases.map { ($0.availabilityKey, defaults.object(forKey: $0.availabilityKey)) }
        defer {
            ShortcutCapture.end()
            for (key, value) in old {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for feature in AppFeature.allCases { defaults.set(false, forKey: feature.availabilityKey) }
        ShortcutCapture.begin()
        let switcher = AppSwitcher.shared
        switcher.syncWithPreferences()
        XCTAssertTrue(switcher.isCapturingShortcut)
        ShortcutCapture.end()
        XCTAssertFalse(switcher.isCapturingShortcut)
    }

    func testDisabledColdServiceDoesNotConstructAnEngine() {
        var created = 0
        let slot = FeatureServiceSlot<Engine>([], isNeeded: { false }, make: {
            created += 1
            return Engine()
        })
        slot.releaseIfUnused()
        XCTAssertNil(slot.existing)
        XCTAssertEqual(created, 0)
    }

    func testDisablingStopsAndReleasesTheLoadedEngine() {
        var enabled = true
        var stopped = 0
        let slot = FeatureServiceSlot<Engine>([], isNeeded: { enabled }, make: { Engine() }, onDisable: {
            $0.running = false
            $0.memory = Data()
            stopped += 1
            return true
        })
        weak var engine = slot.value
        XCTAssertNotNil(engine)
        enabled = false
        slot.releaseIfUnused()
        XCTAssertNil(engine, "The disabled service must leave memory, not only hide")
        XCTAssertNil(slot.existing)
        slot.releaseIfUnused()
        XCTAssertEqual(stopped, 1)
    }

    func testSharedResourceSurvivesUntilItsLastOwnerTurnsOff() {
        var capture = true
        var recording = true
        let slot = FeatureServiceSlot<Engine>([], isNeeded: { capture || recording }, make: { Engine() })
        weak var engine = slot.value
        capture = false
        slot.releaseIfUnused()
        XCTAssertNotNil(engine)
        recording = false
        slot.releaseIfUnused()
        XCTAssertNil(engine)
    }

    func testQuickReenableReusesAnExternallyHeldEngine() {
        var enabled = true
        var created = 0
        let slot = FeatureServiceSlot<Engine>([], isNeeded: { enabled }, make: {
            created += 1
            return Engine()
        })
        var editor: Engine? = slot.value
        enabled = false
        slot.releaseIfUnused()
        enabled = true
        XCTAssertTrue(slot.value === editor)
        XCTAssertEqual(created, 1, "A surviving editor and a reopened feature must not get competing engines")
        editor = nil
        enabled = false
        slot.releaseIfUnused()
        XCTAssertNil(slot.existing)
    }

    func testUnsavedWorkCanRefuseMemoryRelease() {
        let slot = FeatureServiceSlot<Engine>([], isNeeded: { false }, make: { Engine() }, onDisable: { _ in false })
        weak var engine = slot.value
        slot.releaseIfUnused()
        XCTAssertNotNil(engine, "Unsaved work must remain recoverable if storage fails")
    }

    func testConcurrentAccessCreatesOnlyOneEngine() {
        let slot = FeatureServiceSlot<Engine>([], isNeeded: { true }, make: { Engine() })
        let lock = NSLock()
        var identities = Set<ObjectIdentifier>()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let id = ObjectIdentifier(slot.value)
            lock.lock(); identities.insert(id); lock.unlock()
        }
        XCTAssertEqual(identities.count, 1)
    }

    func testDisabledActionsDoNotEnableOrLoadTools() {
        let workspace = UtilityWorkspace.shared
        let defaults = UtilityPreferences.standard
        let previousLibrary = workspace.onOpenFeatureLibrary
        var saved: [String: Any] = [:]
        let tools: [AppFeature] = [.scratchpad, .commandBar, .screenshot, .screenRecorder,
                                   .cameraPreview, .keyboardDebounce, .colorPicker, .micMute]
        for feature in tools {
            if let value = defaults.object(forKey: feature.availabilityKey) { saved[feature.availabilityKey] = value }
            defaults.set(false, forKey: feature.availabilityKey)
        }
        defer {
            workspace.onOpenFeatureLibrary = previousLibrary
            for feature in tools {
                if let value = saved[feature.availabilityKey] { defaults.set(value, forKey: feature.availabilityKey) }
                else { defaults.removeObject(forKey: feature.availabilityKey) }
            }
        }
        var reveals = 0
        workspace.onOpenFeatureLibrary = { reveals += 1 }
        for feature in tools {
            workspace.run(feature.rawValue)
            XCTAssertFalse(feature.isAvailable)
            XCTAssertEqual(workspace.featureToEnable, feature.rawValue)
        }
        XCTAssertEqual(reveals, tools.count)
        workspace.setGlobalMicrophoneMuted(true)
        XCTAssertFalse(AppFeature.micMute.isAvailable)
        XCTAssertEqual(reveals, tools.count + 1)
        XCTAssertNil(ScratchpadService.existing)
        XCTAssertNil(CameraPreviewService.existing)
    }
}

private final class TimedFeatureEngine {
    private let lock = NSLock()
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    private var active = true
    private var count = 0
    let onStopped: () -> Void
    var memory = Data(count: 4 * 1024 * 1024)

    init(firstTick: @escaping () -> Void, stopped: @escaping () -> Void) {
        onStopped = stopped
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.active else { self.lock.unlock(); return }
            self.count += 1
            let first = self.count == 1
            self.lock.unlock()
            if first { firstTick() }
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.resume()
    }

    func stop() {
        lock.lock(); active = false; lock.unlock()
        timer.cancel()
        memory = Data()
    }

    deinit { timer.cancel(); onStopped() }
}

extension FeatureResourceTests {
    func testDisablingClipboardPreservesEditsAfterDeferredSavesDrain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let entry = ClipboardHistoryEntry(text: "Saved fixture")
        try JSONEncoder().encode([entry]).write(to: url)
        let domain = "Anchor.feature-lifecycle-test." + UUID().uuidString
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let service = ClipboardHistoryService(historyURL: url, preferences: preferences)
        XCTAssertTrue(service.updateText(entry, to: "Edited before disabling"))
        XCTAssertTrue(service.releaseResources())
        XCTAssertTrue(service.entries.isEmpty, "The disabled feature must free its in-memory history")
        let drained = expectation(description: "Deferred main-queue saves completed")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        service.flushBeforeTermination()
        let saved = try JSONDecoder().decode([ClipboardHistoryEntry].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.map(\.text), ["Edited before disabling"],
                       "A stale save must never overwrite disk history with the freed memory snapshot")
    }

    func testClipboardWriteFailureKeepsUnsavedEditsRecoverable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let entry = ClipboardHistoryEntry(text: "Original fixture")
        try JSONEncoder().encode([entry]).write(to: url)
        let domain = "Anchor.feature-lifecycle-test." + UUID().uuidString
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let service = ClipboardHistoryService(historyURL: url, preferences: preferences)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertTrue(service.updateText(entry, to: "Recoverable unsaved fixture"))
        XCTAssertFalse(service.prepareForDisable())
        XCTAssertFalse(service.releaseResources())
        XCTAssertEqual(service.entries.map(\.text), ["Recoverable unsaved fixture"])
    }

    func testRetiredImportedIslandAndExtensionsStayUnavailable() {
        let defaults = UtilityPreferences.standard
        let old = AppFeature.allCases.map { ($0.availabilityKey, defaults.object(forKey: $0.availabilityKey)) }
        let keys = [DefaultsKey.notchInitialExtensionsInstalled, DefaultsKey.notchEnabled]
        let oldOptions = keys.map { ($0, defaults.object(forKey: $0)) }
        for feature in AppFeature.allCases { defaults.set(false, forKey: feature.availabilityKey) }
        defaults.set(false, forKey: DefaultsKey.notchInitialExtensionsInstalled)
        defer {
            for (key, value) in old + oldOptions {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let runtime = FeatureRuntime(bindings: [:])
        runtime.setAvailable([.notch], true)
        XCTAssertFalse(AppFeature.notch.isAvailable, "Anchor owns the island renderer")
        XCTAssertTrue(AppFeature.dynamicIslandExtensions.allSatisfy { !$0.isAvailable },
                      "The retired island must not make its imported extensions available")
        runtime.setAvailable([.notch], false)
    }

    func testMasterSwitchStopsRealScheduledWorkAndReleasesItsEngine() {
        let defaults = UtilityPreferences.standard
        let old = AppFeature.allCases.map { ($0.availabilityKey, defaults.object(forKey: $0.availabilityKey)) }
        let oldShortcut = defaults.object(forKey: DefaultsKey.scratchpadShortcutEnabled)
        for feature in AppFeature.allCases { defaults.set(false, forKey: feature.availabilityKey) }
        defer {
            for (key, value) in old {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            if let oldShortcut { defaults.set(oldShortcut, forKey: DefaultsKey.scratchpadShortcutEnabled) }
            else { defaults.removeObject(forKey: DefaultsKey.scratchpadShortcutEnabled) }
        }
        let ticked = expectation(description: "Enabled feature performed scheduled work")
        let stopped = expectation(description: "Disabled feature released its engine")
        var constructions = 0
        let slot = FeatureServiceSlot<TimedFeatureEngine>([.scratchpad], make: {
            constructions += 1
            return TimedFeatureEngine(firstTick: { ticked.fulfill() }, stopped: { stopped.fulfill() })
        }, onDisable: { $0.stop(); return true })
        let runtime = FeatureRuntime(bindings: [.scratchpad: {
            if AppFeature.scratchpad.isAvailable { _ = slot.value }
            else { slot.existing?.stop() }
        }])
        runtime.syncAtLaunch()
        XCTAssertEqual(constructions, 0, "A disabled startup must skip its factory")
        runtime.setAvailable([.scratchpad], true)
        wait(for: [ticked], timeout: 2)
        runtime.setAvailable([.scratchpad], false)
        wait(for: [stopped], timeout: 2)
        XCTAssertFalse(AppFeature.scratchpad.isAvailable)
        XCTAssertNil(slot.existing)
        XCTAssertEqual(constructions, 1)
    }
}
