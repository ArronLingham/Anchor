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
    func testDisabledClipboardPresentationDoesNotLoadHistory() throws {
        let domain = UtilityPreferences.domainName
        guard domain != "com.arronlingham.Anchor.utilities",
              domain != "com.arronlingham.Anchor.dev.utilities" else {
            throw XCTSkip("This test must not change an installed app's preferences")
        }
        guard ClipboardHistoryService.existing == nil else {
            throw XCTSkip("History was already loaded in this test process")
        }
        let defaults = UtilityPreferences.standard
        let key = AppFeature.clipboardHistory.availabilityKey
        let old = defaults.persistentDomain(forName: domain)?[key]
        defer {
            if let old { defaults.set(old, forKey: key) } else { defaults.removeObject(forKey: key) }
            ClipboardHistoryService.noteAvailabilityChange()
        }
        defaults.set(false, forKey: key)
        ClipboardHistoryService.noteAvailabilityChange()
        XCTAssertNil(ClipboardHistoryService.presentationRequest())
        ClipboardHistoryService.showIfAvailable()
        ClipboardHistoryService.schedulePresentation(after: 0)
        XCTAssertNil(ClipboardHistoryService.existing, "An off feature must not construct the history service")
    }

    func testClipboardPresentationTicketsRejectDisabledAndPriorSessions() throws {
        let gate = ClipboardPresentationGate()
        XCTAssertNil(gate.capture(currentlyAvailable: false))
        let first = try XCTUnwrap(gate.capture(currentlyAvailable: true))
        gate.update(available: true)
        XCTAssertTrue(gate.accepts(first, currentlyAvailable: true))
        gate.update(available: true)
        XCTAssertTrue(gate.accepts(first, currentlyAvailable: true), "Unchanged availability must not cancel a request")
        gate.update(available: false)
        XCTAssertFalse(gate.accepts(first, currentlyAvailable: false))
        XCTAssertNil(gate.capture(currentlyAvailable: false))
        gate.update(available: true)
        XCTAssertFalse(gate.accepts(first, currentlyAvailable: true), "A previous enable session must stay invalid")
        let next = try XCTUnwrap(gate.capture(currentlyAvailable: true))
        XCTAssertTrue(gate.accepts(next, currentlyAvailable: true))
        XCTAssertFalse(gate.accepts(next, currentlyAvailable: false), "Current availability is checked at execution")
    }

    func testReplacementUndoWaitsForItsDependentMove() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let replacement = directory.appendingPathComponent("replacement")
        let backup = directory.appendingPathComponent("backup")
        let source = directory.appendingPathComponent("source")
        try Data("new".utf8).write(to: replacement)
        try Data("old".utf8).write(to: backup)
        try Data("conflict".utf8).write(to: source)
        let actions: [WhatsAppDownloadOrganizer.UndoTransaction.Action] = [
            .init(kind: .move, currentPath: replacement.path, restorePath: source.path),
            .init(kind: .move, currentPath: backup.path, restorePath: replacement.path),
        ]
        let transaction = WhatsAppDownloadOrganizer.UndoTransaction(
            id: UUID(), actions: actions, recordsBefore: [], recordsAfter: [], createdAt: Date())
        let blocked = WhatsAppDownloadOrganizer.performUndo(transaction)
        XCTAssertEqual(blocked.completed, 0)
        XCTAssertEqual(blocked.remaining, actions)
        XCTAssertEqual(try Data(contentsOf: replacement), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: backup), Data("old".utf8))

        try FileManager.default.removeItem(at: source)
        let retry = WhatsAppDownloadOrganizer.performUndo(transaction)
        XCTAssertTrue(retry.remaining.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: replacement), Data("old".utf8))
    }

    func testCrossVolumeUndoDoesNotRepeatCompletedTrashStep() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let managed = directory.appendingPathComponent("managed")
        let backup = directory.appendingPathComponent("backup")
        let restored = directory.appendingPathComponent("restored")
        let fakeTrash = directory.appendingPathComponent("fake-trash")
        try Data("managed copy".utf8).write(to: managed)
        try Data("original".utf8).write(to: backup)
        try Data("conflict".utf8).write(to: restored)
        let actions: [WhatsAppDownloadOrganizer.UndoTransaction.Action] = [
            .init(kind: .trash, currentPath: managed.path, restorePath: nil),
            .init(kind: .move, currentPath: backup.path, restorePath: restored.path),
        ]
        var transaction = WhatsAppDownloadOrganizer.UndoTransaction(
            id: UUID(), actions: actions, recordsBefore: [], recordsAfter: [], createdAt: Date())
        let progress = WhatsAppDownloadOrganizer.performUndo(transaction) { url in
            try FileManager.default.moveItem(at: url, to: fakeTrash)
        }
        XCTAssertEqual(progress.completed, 1)
        XCTAssertEqual(progress.remaining, [actions[1]])
        XCTAssertEqual(try Data(contentsOf: fakeTrash), Data("managed copy".utf8))
        XCTAssertEqual(try Data(contentsOf: backup), Data("original".utf8))

        transaction.actions = progress.remaining
        transaction.partial = true
        try FileManager.default.removeItem(at: restored)
        let retry = WhatsAppDownloadOrganizer.performUndo(transaction) { _ in
            XCTFail("A completed Trash step must not be repeated")
        }
        XCTAssertTrue(retry.remaining.isEmpty)
        XCTAssertEqual(try Data(contentsOf: restored), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: fakeTrash), Data("managed copy".utf8))
    }

    func testPartialUndoRetainsOrderedStepsAcrossPersistenceAndRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = (0..<3).map { directory.appendingPathComponent("source-\($0)") }
        let destinations = (0..<3).map { directory.appendingPathComponent("restore-\($0)") }
        for source in sources { try Data("fixture".utf8).write(to: source) }
        try Data("conflict".utf8).write(to: destinations[1])
        let actions = zip(sources, destinations).map {
            WhatsAppDownloadOrganizer.UndoTransaction.Action(kind: .move,
                                                              currentPath: $0.path,
                                                              restorePath: $1.path)
        }
        let oldDate = Date().addingTimeInterval(-9 * 86_400)
        let before = WhatsAppDownloadOrganizer.Record(digest: "before", destinationPath: "/fixture/managed",
                                                       originalName: "before", size: 1, organizedAt: oldDate)
        let after = WhatsAppDownloadOrganizer.Record(digest: "after", destinationPath: "/fixture/managed",
                                                      originalName: "after", size: 2, organizedAt: oldDate)
        let unrelated = WhatsAppDownloadOrganizer.Record(digest: "other", destinationPath: "/fixture/other",
                                                          originalName: "other", size: 3, organizedAt: oldDate)
        let transaction = WhatsAppDownloadOrganizer.UndoTransaction(
            id: UUID(), actions: actions, recordsBefore: [before, unrelated],
            recordsAfter: [after, unrelated], createdAt: oldDate)
        let legacyData = try JSONEncoder().encode(transaction)
        let legacy = try JSONDecoder().decode(WhatsAppDownloadOrganizer.UndoTransaction.self, from: legacyData)
        XCTAssertNil(legacy.partial, "Older undo records without a partial marker must still decode")
        try Data("first conflict".utf8).write(to: destinations[0])
        let noProgress = WhatsAppDownloadOrganizer.performUndo(transaction)
        XCTAssertEqual(noProgress.completed, 0)
        XCTAssertEqual(noProgress.remaining, actions)
        try FileManager.default.removeItem(at: destinations[0])
        let progress = WhatsAppDownloadOrganizer.performUndo(transaction)
        XCTAssertEqual(progress.completed, 1)
        XCTAssertEqual(progress.remaining, Array(actions.dropFirst()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinations[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sources[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sources[2].path),
                      "Later dependent actions must not run after a failure")

        let domain = "Anchor.partial-undo-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        WhatsAppDownloadOrganizer.saveRecords([after, unrelated], defaults: defaults)
        WhatsAppDownloadOrganizer.saveUndoTransactions([transaction], defaults: defaults)
        XCTAssertEqual(WhatsAppDownloadOrganizer.commitUndoProgress(
            transaction, transactions: [transaction], progress: noProgress, defaults: defaults), .failed)
        XCTAssertNil(WhatsAppDownloadOrganizer.loadUndoTransactions(defaults: defaults).first?.partial)
        XCTAssertEqual(WhatsAppDownloadOrganizer.commitUndoProgress(
            transaction, transactions: [transaction], progress: progress, defaults: defaults), .partial)
        let restored = try XCTUnwrap(WhatsAppDownloadOrganizer.loadUndoTransactions(defaults: defaults).first)
        XCTAssertEqual(restored.actions, progress.remaining)
        XCTAssertTrue(restored.partial == true)
        XCTAssertEqual(WhatsAppDownloadOrganizer.loadRecords(defaults: defaults), [after, unrelated])
        XCTAssertTrue(WhatsAppDownloadOrganizer.recordsAllowUndo(restored, current: [after, unrelated]))
        XCTAssertFalse(WhatsAppDownloadOrganizer.recordsAllowUndo(restored, current: [before, unrelated]),
                       "A later conflicting record change must not be overwritten")
        let discardDomain = domain + ".discard"
        let discardDefaults = UserDefaults(suiteName: discardDomain)!
        defer { discardDefaults.removePersistentDomain(forName: discardDomain) }
        let otherUndo = WhatsAppDownloadOrganizer.UndoTransaction(
            id: UUID(), actions: [], recordsBefore: [], recordsAfter: [], createdAt: oldDate.addingTimeInterval(60))
        var otherPartial = otherUndo
        otherPartial.partial = true
        WhatsAppDownloadOrganizer.saveRecords([after, unrelated], defaults: discardDefaults)
        WhatsAppDownloadOrganizer.saveUndoTransactions([restored, otherUndo, otherPartial], defaults: discardDefaults)
        XCTAssertFalse(WhatsAppDownloadOrganizer.discardPartialUndoTransaction(id: otherPartial.id, defaults: discardDefaults),
                       "A confirmation must not discard a different pending entry")
        XCTAssertTrue(WhatsAppDownloadOrganizer.discardPartialUndoTransaction(id: restored.id, defaults: discardDefaults))
        XCTAssertEqual(WhatsAppDownloadOrganizer.loadUndoTransactions(defaults: discardDefaults).map(\.id),
                       [otherUndo.id, otherPartial.id], "Discard must preserve unrelated undo history")
        XCTAssertEqual(WhatsAppDownloadOrganizer.loadRecords(defaults: discardDefaults), [after, unrelated],
                       "Discard must not remove managed-file records")
        XCTAssertFalse(WhatsAppDownloadOrganizer.discardPartialUndoTransaction(id: restored.id, defaults: discardDefaults))
        XCTAssertTrue(WhatsAppDownloadOrganizer.discardPartialUndoTransaction(id: otherPartial.id, defaults: discardDefaults))
        XCTAssertEqual(WhatsAppDownloadOrganizer.loadUndoTransactions(defaults: discardDefaults).map(\.id), [otherUndo.id])
        XCTAssertEqual(WhatsAppDownloadOrganizer.validUndoTransactions([restored]).count, 1,
                       "A partial undo must not expire while it remains unresolved")
        XCTAssertTrue(WhatsAppDownloadOrganizer.validUndoTransactions([transaction]).isEmpty)

        try FileManager.default.removeItem(at: destinations[1])
        let retry = WhatsAppDownloadOrganizer.performUndo(restored)
        XCTAssertTrue(retry.remaining.isEmpty)
        XCTAssertEqual(retry.completed, 2)
        XCTAssertEqual(WhatsAppDownloadOrganizer.commitUndoProgress(
            restored, transactions: [restored], progress: retry, defaults: defaults), .complete)
        XCTAssertTrue(WhatsAppDownloadOrganizer.loadUndoTransactions(defaults: defaults).isEmpty)
        XCTAssertEqual(Set(WhatsAppDownloadOrganizer.loadRecords(defaults: defaults).map(\.digest)),
                       Set(["before", "other"]))
        for destination in destinations { XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path)) }
        for source in sources { XCTAssertFalse(FileManager.default.fileExists(atPath: source.path)) }
    }

    @MainActor
    func testRestoredCleanerReconcilesChildPreferencesDuringCleanup() throws {
        let domain = UtilityPreferences.domainName
        guard domain != "com.arronlingham.Anchor.utilities",
              domain != "com.arronlingham.Anchor.dev.utilities" else {
            throw XCTSkip("This test must not change an installed app's preferences")
        }
        let defaults = UtilityPreferences.standard
        let keys = AppFeature.allCases.map(\.availabilityKey)
            + [DefaultsKey.whatsAppDownloadsEnabled, "Anchor.integrationPrepared.v1"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "Anchor.integrationPrepared.v1")
        for feature in AppFeature.allCases { defaults.set(false, forKey: feature.availabilityKey) }
        defaults.set(true, forKey: AppFeature.cleaner.availabilityKey)
        defaults.set(true, forKey: DefaultsKey.whatsAppDownloadsEnabled)

        let started = expectation(description: "cleanup started")
        let finished = expectation(description: "cleanup finished")
        let resumed = expectation(description: "restored Cleaner reconciled")
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let manager = WhatsAppDownloadManager.shared
        manager.reset()
        XCTAssertTrue(manager.performCleanup(work: {
            started.fulfill()
            resume.wait()
        }, finish: { _ in finished.fulfill() }))
        wait(for: [started], timeout: 2)
        let runtime = FeatureRuntime(bindings: [.cleaner: {
            XCTAssertTrue(AppFeature.cleaner.isAvailable)
            XCTAssertFalse(WhatsAppDownloadSupport.isEnabled)
            resumed.fulfill()
        }])
        defaults.set(false, forKey: DefaultsKey.whatsAppDownloadsEnabled)
        defaults.set(false, forKey: AppFeature.cleaner.availabilityKey)
        runtime.reconcileAvailability()
        XCTAssertTrue(AppFeature.cleaner.isAvailable, "An active cleanup must keep Cleaner enabled")
        wait(for: [resumed], timeout: 1)
        resume.signal()
        wait(for: [finished], timeout: 2)
        manager.reset()
    }

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

    func testClipboardSettingsOnlyLoadsHistoryWhileAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let entry = ClipboardHistoryEntry(text: "Saved fixture")
        let original = try JSONEncoder().encode([entry])
        try original.write(to: url)
        let domain = "Anchor.clipboard-settings-test." + UUID().uuidString
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        var constructions = 0
        let observation = ClipboardHistorySettingsObservation(available: false) {
            constructions += 1
            return ClipboardHistoryService(historyURL: url, preferences: preferences)
        }
        XCTAssertNil(observation.history)
        XCTAssertEqual(constructions, 0)
        observation.synchronize(available: true)
        XCTAssertEqual(observation.history?.entries.map(\.id), [entry.id])
        observation.synchronize(available: true)
        XCTAssertEqual(constructions, 1)
        observation.synchronize(available: false)
        XCTAssertNil(observation.history)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testClipboardClearConfirmationRejectsPriorAvailabilitySession() throws {
        let gate = ClipboardPresentationGate()
        gate.update(available: true)
        let ticket = try XCTUnwrap(gate.capture(currentlyAvailable: true))
        let entry = ClipboardHistoryEntry(text: "Fixture")
        let request = ClipboardClearRecentRequest(entryIDs: [entry.id: entry.copiedAt], ticket: ticket)
        var cleared: [UUID: Date]?
        let accept = { (ticket: UUID) in gate.accepts(ticket, currentlyAvailable: true) }
        request.performIfCurrent(accepts: accept) { cleared = $0 }
        XCTAssertEqual(cleared, request.entryIDs)
        cleared = nil
        gate.update(available: false)
        gate.update(available: true)
        request.performIfCurrent(accepts: accept) { cleared = $0 }
        XCTAssertNil(cleared, "An old confirmation must not clear a new session's history")
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
