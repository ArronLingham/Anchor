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
        let oldSwitcherEnabled = defaults.object(forKey: DefaultsKey.switcherEnabled)
        defer {
            ShortcutCapture.end()
            for (key, value) in old {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            if let oldSwitcherEnabled { defaults.set(oldSwitcherEnabled, forKey: DefaultsKey.switcherEnabled) }
            else { defaults.removeObject(forKey: DefaultsKey.switcherEnabled) }
        }
        for feature in AppFeature.allCases { defaults.set(false, forKey: feature.availabilityKey) }
        defaults.set(false, forKey: DefaultsKey.switcherEnabled)
        ShortcutCapture.begin()
        defaults.set(true, forKey: AppFeature.switcher.availabilityKey)
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
    @MainActor
    func testWhatsAppPreferenceObserverSeesExternalWrite() throws {
        let domain = "Anchor.whatsapp-external-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let changed = expectation(description: "external switch change delivered")
        var observer: WhatsAppPreferenceObserver? = WhatsAppPreferenceObserver(defaults: defaults) { key, value in
            if key == DefaultsKey.whatsAppDownloadsEnabled, value { changed.fulfill() }
        }
        XCTAssertNotNil(observer)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", domain, DefaultsKey.whatsAppDownloadsEnabled, "-bool", "YES"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        wait(for: [changed], timeout: 5)
        observer = nil
    }

    @MainActor
    func testWhatsAppPreferenceObserverKeepsRapidTransitions() {
        let domain = "Anchor.whatsapp-observer-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let changed = expectation(description: "each transition delivered")
        changed.expectedFulfillmentCount = 5
        var events: [(String, Bool)] = []
        var observer: WhatsAppPreferenceObserver? = WhatsAppPreferenceObserver(defaults: defaults) { key, value in
            events.append((key, value))
            changed.fulfill()
        }
        XCTAssertNotNil(observer)
        defaults.set(true, forKey: DefaultsKey.whatsAppDownloadsEnabled)
        defaults.set(false, forKey: DefaultsKey.whatsAppDownloadsEnabled)
        defaults.set(true, forKey: DefaultsKey.whatsAppDownloadsEnabled)
        defaults.set(true, forKey: DefaultsKey.whatsAppDownloadsAutomaticEnabled)
        defaults.set(false, forKey: DefaultsKey.whatsAppDownloadsAutomaticEnabled)
        wait(for: [changed], timeout: 2)
        XCTAssertEqual(events.map(\.0), [DefaultsKey.whatsAppDownloadsEnabled,
                                         DefaultsKey.whatsAppDownloadsEnabled,
                                         DefaultsKey.whatsAppDownloadsEnabled,
                                         DefaultsKey.whatsAppDownloadsAutomaticEnabled,
                                         DefaultsKey.whatsAppDownloadsAutomaticEnabled])
        XCTAssertEqual(events.map(\.1), [true, false, true, true, false])
        observer = nil
    }

    @MainActor
    func testResetCancelsScanAndNewScanCanFinish() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["first", "second"].map { directory.appendingPathComponent($0) }
        for file in files { try Data("fixture".utf8).write(to: file) }
        let manager = WhatsAppDownloadManager()
        let started = expectation(description: "first scan entered classification")
        let nextFinished = expectation(description: "new scan finished")
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        XCTAssertTrue(manager.performScan(work: { cancellation -> [String]? in
            var visited: [String] = []
            let result = cancellation.compactMap(files) { file -> String? in
                visited.append(file.lastPathComponent)
                if visited.count == 1 {
                    started.fulfill()
                    resume.wait()
                }
                return try? String(contentsOf: file, encoding: .utf8)
            }
            XCTAssertNil(result)
            XCTAssertEqual(visited, ["first"], "Cancellation must stop later file classification")
            return result
        }, finish: { _ in XCTFail("A cancelled scan must not publish results") }))
        wait(for: [started], timeout: 2)
        manager.reset()
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertTrue(manager.performScan(work: { _ in 42 }, finish: { result in
            XCTAssertEqual(result, 42)
            nextFinished.fulfill()
        }))
        resume.signal()
        wait(for: [nextFinished], timeout: 2)
        XCTAssertEqual(manager.phase, .idle)
    }

    @MainActor
    func testCleanupResetKeepsActiveCompletionAndBlocksOverlap() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let destination = directory.appendingPathComponent("moved.txt")
        try Data("fixture".utf8).write(to: source)
        let domain = "Anchor.cleanup-transaction-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = WhatsAppDownloadManager(preferences: defaults)
        let started = expectation(description: "cleanup started")
        let completed = expectation(description: "cleanup result recorded")
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let accepted = manager.performCleanup(work: { () -> Bool in
            started.fulfill()
            resume.wait()
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                return true
            } catch { return false }
        }, finish: { success in
            XCTAssertTrue(success)
            manager.recordCleanup(moved: 1, bytes: 7, failed: 0, automatic: true)
            completed.fulfill()
        })
        XCTAssertTrue(accepted)
        wait(for: [started], timeout: 2)
        manager.reset()
        manager.reset()
        XCTAssertEqual(manager.phase, .cleaning)
        XCTAssertFalse(manager.performCleanup(work: { () }, finish: { _ in }))
        manager.scan() // A scan cannot replace an active cleanup.
        XCTAssertEqual(manager.phase, .cleaning)
        resume.signal()
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(defaults.integer(forKey: DefaultsKey.whatsAppDownloadsLastCleanupCount), 1)
        XCTAssertEqual(defaults.integer(forKey: DefaultsKey.whatsAppDownloadsLastCleanupBytes), 7)
        XCTAssertGreaterThan(defaults.double(forKey: DefaultsKey.whatsAppDownloadsLastAutoRun), 0)
    }

    @MainActor
    func testOrganizerStopKeepsMoveAndUndoCompletions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.txt")
        let moved = directory.appendingPathComponent("moved.txt")
        try Data("fixture".utf8).write(to: original)

        for (phase, source, destination) in [(WhatsAppDownloadOrganizer.Phase.organizing, original, moved),
                                             (.undoing, moved, original)] {
            let organizer = WhatsAppDownloadOrganizer()
            let started = expectation(description: "worker started")
            let completed = expectation(description: "transaction recorded")
            let resume = DispatchSemaphore(value: 0)
            defer { resume.signal() }
            let journal = directory.appendingPathComponent("journal-\(UUID().uuidString)")
            let accepted = organizer.performMutation(phase: phase, work: { () -> Bool in
                started.fulfill()
                resume.wait()
                do {
                    try FileManager.default.moveItem(at: source, to: destination)
                    return true
                } catch { return false }
            }, finish: { success in
                XCTAssertTrue(success)
                do { try Data("recorded".utf8).write(to: journal) }
                catch { XCTFail("Could not write transaction record: \(error)") }
                completed.fulfill()
            })
            XCTAssertTrue(accepted)
            wait(for: [started], timeout: 2)
            organizer.stop()
            organizer.stop()
            XCTAssertTrue(organizer.isBusy, "Stopping monitoring must not abandon an active transaction")
            XCTAssertFalse(organizer.performMutation(phase: phase, work: { () }, finish: { _ in }),
                           "A second operation must not overlap the first")
            resume.signal()
            wait(for: [completed], timeout: 2)
            XCTAssertFalse(organizer.isBusy)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try Data(contentsOf: journal), Data("recorded".utf8))
        }
    }

    func testCaptureDisablementProtectsWorkWithoutBlockingOtherOwners() {
        XCTAssertNotNil(CaptureDisablementGuard.reason(for: .screenshot, screenshotEditor: true))
        XCTAssertNil(CaptureDisablementGuard.reason(for: .screenRecorder, screenshotEditor: true))
        XCTAssertNotNil(CaptureDisablementGuard.reason(for: .screenRecorder, recorderEditor: true))
        XCTAssertNotNil(CaptureDisablementGuard.reason(for: .screenRecorder, recording: true))
        XCTAssertNil(CaptureDisablementGuard.reason(for: .mediaTools, recorderEditor: true, recording: true))
        XCTAssertNotNil(CaptureDisablementGuard.reason(for: .mediaTools, mediaEditor: true))
        XCTAssertNil(CaptureDisablementGuard.reason(for: .screenRecorder, mediaEditor: true))
        XCTAssertNil(CaptureDisablementGuard.reason(for: .screenshot))
        XCTAssertNil(CaptureDisablementGuard.reason(for: .screenRecorder))
        XCTAssertNil(CaptureDisablementGuard.reason(for: .mediaTools))
    }

    func testClipboardClearPreservesPinnedAndRecopiedItems() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let removed = ClipboardHistoryEntry(text: "confirmed")
        let pinned = ClipboardHistoryEntry(text: "pinned", pinnedAt: Date())
        let recopied = ClipboardHistoryEntry(text: "recopied")
        let later = ClipboardHistoryEntry(text: "later")
        try JSONEncoder().encode([removed, pinned, recopied, later]).write(to: url)
        let domain = "Anchor.clipboard-clear-test." + UUID().uuidString
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let service = ClipboardHistoryService(historyURL: url, preferences: preferences)

        var confirmed = service.recentEntriesSnapshot
        confirmed[recopied.id] = recopied.copiedAt.addingTimeInterval(-1)
        confirmed.removeValue(forKey: later.id)
        service.clearRecent(confirmed)

        XCTAssertEqual(Set(service.entries.map(\.id)), Set([pinned.id, recopied.id, later.id]))
        service.flushBeforeTermination()
    }

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
