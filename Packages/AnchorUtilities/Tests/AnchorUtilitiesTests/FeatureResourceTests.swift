import Foundation
import CoreGraphics
import XCTest
@testable import AnchorUtilities

final class FeatureResourceTests: XCTestCase {
    func testScreenshotEditorWaitsForHistoryDiscardAndAllowsRetry() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let capture = ScreenshotSelectionController.Capture(image: try XCTUnwrap(context.makeImage()),
                                                            scale: 1, anchorRect: .zero)
        let editor = ScreenshotEditorController(capture: capture)
        var completions: [(Bool) -> Void] = []
        editor.discardHistory = { completions.append($0) }
        editor.discardAndClose()
        XCTAssertTrue(editor.model.discardInProgress)
        XCTAssertFalse(editor.explicitlyResolved)
        editor.discardAndClose()
        XCTAssertEqual(completions.count, 1)
        completions.removeFirst()(false)
        XCTAssertFalse(editor.model.discardInProgress)
        XCTAssertFalse(editor.explicitlyResolved)
        editor.discardAndClose()
        XCTAssertTrue(editor.model.discardInProgress)
        completions.removeFirst()(true)
        XCTAssertFalse(editor.model.discardInProgress)
        XCTAssertTrue(editor.explicitlyResolved)
    }

    func testScreenshotDiscardRetryDoesNotReopenAfterSuccess() {
        let recovery = ScreenshotDiscardRecovery()
        recovery.begin()
        XCTAssertFalse(recovery.finish(success: false, previewOpen: true))
        recovery.begin()
        XCTAssertFalse(recovery.takeForClose(), "A pending retry determines its own outcome")
        XCTAssertFalse(recovery.finish(success: true, previewOpen: false))
        XCTAssertFalse(recovery.takeForClose())

        recovery.begin()
        XCTAssertFalse(recovery.finish(success: false, previewOpen: true))
        recovery.begin()
        XCTAssertFalse(recovery.takeForClose())
        XCTAssertTrue(recovery.finish(success: false, previewOpen: false))
        XCTAssertFalse(recovery.takeForClose())

        recovery.begin()
        XCTAssertFalse(recovery.finish(success: false, previewOpen: true))
        XCTAssertTrue(recovery.takeForEdit())
        XCTAssertFalse(recovery.takeForClose())
        recovery.begin()
        XCTAssertFalse(recovery.finish(success: false, previewOpen: true))
        recovery.resolve()
        XCTAssertFalse(recovery.takeForClose())
    }

    func testScreenshotDiscardRewindsNumberOnlyAfterTrashSucceeds() {
        let url = URL(fileURLWithPath: "/unused/screenshot.png")
        var rewound: [Int] = []
        let failed = ScreenshotService.trashSavedCapture(at: url, consumedNumber: 7,
            trash: { _ in throw CocoaError(.fileWriteNoPermission) },
            rewind: { rewound.append($0) })
        XCTAssertFalse(failed)
        XCTAssertTrue(rewound.isEmpty)
        let succeeded = ScreenshotService.trashSavedCapture(at: url, consumedNumber: 7,
            trash: { XCTAssertEqual($0, url) }, rewind: { rewound.append($0) })
        XCTAssertTrue(succeeded)
        XCTAssertEqual(rewound, [7])
    }

    func testScreenshotHistoryWritesRespectPerCaptureDecisions() {
        final class Editor {}
        let writes = ScreenshotHistoryWrites<String, Editor>()
        let first = UUID(), second = UUID(), third = UUID(), fourth = UUID()
        let editor = Editor()
        writes.begin(first, capture: "discarded")
        writes.begin(second, capture: "editing")
        writes.begin(third, capture: "older")
        writes.begin(fourth, capture: "saved")
        writes.associate(second, editor: editor)
        writes.resolve(first)
        writes.resolve(fourth)
        XCTAssertNil(writes.finish(first, success: false))
        XCTAssertNil(writes.finish(fourth, success: false))
        let oldFailure = writes.finish(third, success: false)
        XCTAssertEqual(oldFailure?.capture, "older")
        XCTAssertNil(oldFailure?.editor)
        let editingFailure = writes.finish(second, success: false)
        XCTAssertTrue(editingFailure?.editor === editor)
        XCTAssertEqual(editingFailure?.capture, "editing")
        XCTAssertTrue(writes.isEmpty)

        writes.begin(first, capture: "closed editor")
        writes.associate(first, editor: editor)
        writes.resolve(editor: editor)
        XCTAssertNil(writes.finish(first, success: false))
        writes.begin(first, capture: "closed without an explicit discard")
        writes.associate(first, editor: editor)
        writes.detach(editor: editor)
        let closedFailure = writes.finish(first, success: false)
        XCTAssertEqual(closedFailure?.capture, "closed without an explicit discard")
        XCTAssertNil(closedFailure?.editor)
        writes.begin(second, capture: "committed")
        XCTAssertNil(writes.finish(second, success: true))
        XCTAssertTrue(writes.isEmpty)

        // Preview Edit closes its preview before opening the editor on the
        // next main-queue turn; a result arriving there must wait for it.
        writes.begin(first, capture: "deferred edit")
        writes.beginEditing(first)
        XCTAssertNil(writes.finish(first, success: false))
        XCTAssertFalse(writes.isEmpty)
        XCTAssertTrue(writes.associate(first, editor: editor))
        XCTAssertTrue(writes.isEmpty)
        writes.begin(second, capture: "successful deferred edit")
        writes.beginEditing(second)
        XCTAssertNil(writes.finish(second, success: true))
        XCTAssertFalse(writes.associate(second, editor: editor))
        XCTAssertTrue(writes.isEmpty)
    }

    func testScreenshotHistoryReportsCommittedAndFailedWrites() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let capture = ScreenshotSelectionController.Capture(image: try XCTUnwrap(context.makeImage()),
                                                            scale: 1, anchorRect: CGRect(x: 0, y: 0, width: 4, height: 4))
        let goodRoot = base.appendingPathComponent("good")
        let good = RecentCaptureService(directoryOverride: goodRoot, loadOnInit: false)
        let committed = expectation(description: "committed")
        good.recordScreenshot(capture) { success in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(success)
            committed.fulfill()
        }
        wait(for: [committed], timeout: 5)
        let index = try Data(contentsOf: goodRoot.appendingPathComponent("history.json"))
        let entries = try JSONDecoder().decode([RecentCaptureEntry].self, from: index)
        XCTAssertEqual(entries.count, 1)
        let name = try XCTUnwrap(entries.first?.screenshotName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: goodRoot.appendingPathComponent(name).path))

        // The discard request can arrive before the capture write finishes.
        let discardID = UUID()
        let queuedWrite = expectation(description: "queued capture")
        let discarded = expectation(description: "queued discard")
        good.recordScreenshot(capture, id: discardID) { success in
            XCTAssertTrue(success)
            queuedWrite.fulfill()
        }
        good.removeScreenshot(id: discardID) { success in
            XCTAssertTrue(success)
            discarded.fulfill()
        }
        wait(for: [queuedWrite, discarded], timeout: 5)
        let afterDiscard = try JSONDecoder().decode([RecentCaptureEntry].self,
            from: Data(contentsOf: goodRoot.appendingPathComponent("history.json")))
        XCTAssertEqual(afterDiscard, entries)
        XCTAssertTrue(FileManager.default.fileExists(atPath: goodRoot.appendingPathComponent(name).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: goodRoot.appendingPathComponent("\(discardID.uuidString).png").path))

        let failingRemoval = RecentCaptureService(directoryOverride: goodRoot, loadOnInit: false,
                                                   persistOverride: { _ in false })
        let deletionFailure = expectation(description: "failed removal")
        failingRemoval.removeScreenshot(id: entries[0].id) { success in
            XCTAssertFalse(success)
            deletionFailure.fulfill()
        }
        wait(for: [deletionFailure], timeout: 5)
        XCTAssertTrue(failingRemoval.prepareForDisable())
        XCTAssertEqual(try JSONDecoder().decode([RecentCaptureEntry].self,
            from: Data(contentsOf: goodRoot.appendingPathComponent("history.json"))), entries)
        XCTAssertTrue(FileManager.default.fileExists(atPath: goodRoot.appendingPathComponent(name).path))

        let failedRoot = base.appendingPathComponent("failed")
        let failed = RecentCaptureService(directoryOverride: failedRoot, loadOnInit: false,
                                          persistOverride: { _ in false })
        let failedWrite = expectation(description: "failed index write")
        failed.recordScreenshot(capture) { success in
            XCTAssertFalse(success)
            failedWrite.fulfill()
        }
        wait(for: [failedWrite], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedRoot.appendingPathComponent("history.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: failedRoot.path).filter { $0.hasSuffix(".png") }.count, 2)
        XCTAssertTrue(failed.prepareForDisable())
        let restoredEmpty = try JSONDecoder().decode([RecentCaptureEntry].self,
            from: Data(contentsOf: failedRoot.appendingPathComponent("history.json")))
        XCTAssertTrue(restoredEmpty.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: failedRoot.path).filter { $0.hasSuffix(".png") }.isEmpty)

        // An atomic replacement may have succeeded before a later filesystem
        // error. A retry must rewrite the previous index before cleanup.
        let ambiguous = RecentCaptureService(directoryOverride: goodRoot, loadOnInit: false,
                                              persistOverride: { store in
            XCTAssertTrue(store.persist())
            return false
        })
        let ambiguousWrite = expectation(description: "ambiguous committed write")
        ambiguous.recordScreenshot(capture) { success in
            XCTAssertFalse(success)
            ambiguousWrite.fulfill()
        }
        wait(for: [ambiguousWrite], timeout: 5)
        let ambiguousIndex = goodRoot.appendingPathComponent("history.json")
        XCTAssertEqual(try JSONDecoder().decode([RecentCaptureEntry].self,
            from: Data(contentsOf: ambiguousIndex)).count, 2)
        XCTAssertTrue(ambiguous.prepareForDisable())
        let restored = try JSONDecoder().decode([RecentCaptureEntry].self, from: Data(contentsOf: ambiguousIndex))
        XCTAssertEqual(restored, entries)
        XCTAssertTrue(FileManager.default.fileExists(atPath: goodRoot.appendingPathComponent(name).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: goodRoot.path).filter { $0.hasSuffix(".png") }.count, 2)

        let badRoot = base.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: badRoot, withIntermediateDirectories: true)
        let corrupt = Data("not an index".utf8)
        let corruptURL = badRoot.appendingPathComponent("history.json")
        try corrupt.write(to: corruptURL)
        let unreadable = RecentCaptureService(directoryOverride: badRoot, loadOnInit: false)
        let failedLoad = expectation(description: "unreadable index")
        unreadable.recordScreenshot(capture) { success in
            XCTAssertFalse(success)
            failedLoad.fulfill()
        }
        wait(for: [failedLoad], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: corruptURL), corrupt)
    }

    func testRadialMenuActionTicketsSurviveDismissalButNotDisable() throws {
        let gate = RadialMenuActionGate()
        let on = RadialMenuActionGate.State(available: true, enabled: true)
        let off = RadialMenuActionGate.State(available: true, enabled: false)
        gate.update(state: on)
        let ticket = try XCTUnwrap(gate.capture(preview: false, state: on))
        // Closing the visible wheel does not update the feature lifecycle.
        XCTAssertTrue(gate.accepts(ticket, state: on))
        XCTAssertFalse(gate.accepts(ticket, state: off))
        gate.update(state: off)
        gate.update(state: on)
        XCTAssertFalse(gate.accepts(ticket, state: on))
        let next = try XCTUnwrap(gate.capture(preview: false, state: on))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(next, state: on))
    }

    func testRadialMenuPreviewHasScopedOffStateAuthorization() throws {
        let gate = RadialMenuActionGate()
        let off = RadialMenuActionGate.State(available: true, enabled: false)
        let uninstalled = RadialMenuActionGate.State(available: false, enabled: false)
        gate.update(state: off)
        XCTAssertNil(gate.capture(preview: false, state: off))
        let preview = try XCTUnwrap(gate.capture(preview: true, state: off))
        gate.update(state: off) // An unrelated re-sync is not a transition.
        XCTAssertTrue(gate.accepts(preview, state: off))
        gate.update(state: uninstalled)
        XCTAssertFalse(gate.accepts(preview, state: uninstalled))
        gate.update(state: off)
        XCTAssertFalse(gate.accepts(preview, state: off))
    }

    func testRadialMenuDeferredActionChecksSessionAndDestination() throws {
        let gate = RadialMenuActionGate()
        let on = RadialMenuActionGate.State(available: true, enabled: true)
        let off = RadialMenuActionGate.State(available: true, enabled: false)
        gate.update(state: on)
        var state = on
        var destination = true
        var actions = 0
        let first = try XCTUnwrap(gate.capture(preview: false, state: state))
        let queued = {
            if gate.accepts(first, state: state) && destination { actions += 1 }
        }
        state = off
        gate.update(state: off)
        state = on
        gate.update(state: on)
        queued()
        XCTAssertEqual(actions, 0)
        let current = try XCTUnwrap(gate.capture(preview: false, state: state))
        destination = false
        if gate.accepts(current, state: state) && destination { actions += 1 }
        XCTAssertEqual(actions, 0)
        destination = true
        if gate.accepts(current, state: state) && destination { actions += 1 }
        XCTAssertEqual(actions, 1)
    }

    func testRadialMenuDisableRejectsLateNowPlayingResult() {
        var completion: ((RadialNowPlayingSnapshot?) -> Void)?
        let service = RadialNowPlayingService(fetch: { completion = $0 })
        var updates: [RadialNowPlayingState] = []
        service.refresh { updates.append($0) }
        service.presentDetails(at: .zero)
        XCTAssertEqual(updates, [.loading])
        service.suspend()
        completion?(nil)
        let drained = expectation(description: "late result delivered")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(updates, [.loading])
        XCTAssertEqual(service.state, .nothingPlaying)
    }

    func testMicrophoneQueuedMuteLosesAuthorizationAcrossDisable() throws {
        let gate = ClipboardPresentationGate()
        gate.update(available: true)
        let ticket = try XCTUnwrap(gate.capture(currentlyAvailable: true))
        XCTAssertTrue(gate.accepts(ticket, currentlyAvailable: true))
        gate.update(available: false)
        gate.update(available: true)
        XCTAssertFalse(gate.accepts(ticket, currentlyAvailable: true))
    }

    func testMicrophoneMuteStopsAfterDisableBeforeDeviceWrite() {
        let newMic = MicMuteService.InputDevice(id: 1, uid: "new")
        let existingMic = MicMuteService.InputDevice(id: 2, uid: "existing")
        var allowed = true
        var writes = 0
        let backend = MicMuteService.MuteBackend(
            muteSwitch: { _ in .unavailable }, setMute: { _, _ in writes += 1; return .confirmed },
            isSilenced: { _ in false }, volume: { _ in 0.5 }, channels: { _ in ["1": 0.5] },
            volumeSnapshotMatches: { _, _, _ in true }, setVolume: { _, _ in writes += 1; return true },
            volumeMuteVerified: { _, _ in true }, isActiveNonAggregate: { _ in true },
            prepareWrite: { _ in allowed = false; return true }, mayMute: { allowed })
        let outcome = MicMuteService.mute(
            [newMic, existingMic], savedVolumes: ["existing": 0.7],
            savedChannelVolumes: ["existing": ["1": 0.7]], mutedDevices: ["existing"], backend: backend)
        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(outcome.mutedDevices, ["existing"])
        XCTAssertEqual(outcome.savedVolumes, ["existing": 0.7])
        XCTAssertEqual(outcome.savedChannelVolumes, ["existing": ["1": 0.7]])
    }

    func testMicrophoneMuteStopsAfterDisableBeforeSwitchWrite() {
        let mic = MicMuteService.InputDevice(id: 1, uid: "mic")
        var allowed = true
        var writes = 0
        let backend = MicMuteService.MuteBackend(
            muteSwitch: { _ in .value(0) }, setMute: { _, _ in writes += 1; return .confirmed },
            isSilenced: { _ in false }, volume: { _ in 0.5 }, channels: { _ in [:] },
            volumeSnapshotMatches: { _, _, _ in true }, setVolume: { _, _ in writes += 1; return true },
            volumeMuteVerified: { _, _ in true }, isActiveNonAggregate: { _ in true },
            prepareWrite: { _ in allowed = false; return true }, mayMute: { allowed })
        let outcome = MicMuteService.mute([mic], savedVolumes: [:], savedChannelVolumes: [:],
                                           mutedDevices: [], backend: backend)
        XCTAssertTrue(outcome.cancelled)
        XCTAssertFalse(outcome.didWrite)
        XCTAssertEqual(writes, 0)
    }

    func testMicrophoneCancelledPreparedWriteKeepsLegacyOwnershipUntouched() throws {
        let suite = "anchor.test.mic-write-ahead.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MicMuteWriteAhead(defaults: defaults, key: "pending")
        XCTAssertNil(defaults.object(forKey: DefaultsKey.micMuteMutedDevices))
        XCTAssertTrue(store.append(.init(uid: "new", kind: .muteSwitch, volume: nil, channels: [:])))
        let failed = MicMuteWriteAhead(defaults: defaults, key: "pending", synchronize: { false })
        XCTAssertFalse(failed.abandonWithoutWrite())
        guard case .valid = store.load() else { return XCTFail("Failed cleanup lost the record") }
        XCTAssertTrue(store.abandonWithoutWrite())
        XCTAssertNil(defaults.object(forKey: DefaultsKey.micMuteMutedDevices))
        guard case .none = store.load() else { return XCTFail("Cancelled record was not cleared") }
    }

    func testMicrophoneWriteAheadRetainsEveryPreparedDevice() throws {
        XCTAssertFalse(MicMuteSupport.isInterruptedWrite(recordPresent: true, inFlightSweeps: 1))
        XCTAssertTrue(MicMuteSupport.isInterruptedWrite(recordPresent: true, inFlightSweeps: 0))
        XCTAssertFalse(MicMuteSupport.isInterruptedWrite(recordPresent: false, inFlightSweeps: 0))
        let suite = "anchor.test.mic-write-ahead.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MicMuteWriteAhead(defaults: defaults, key: "pending")
        XCTAssertFalse(store.append(.init(uid: "bad", kind: .volume, volume: 2, channels: [:])))
        guard case .none = store.load() else { return XCTFail("Invalid entry created a record") }
        let first = MicMuteWriteAhead.Entry(uid: "one", kind: .volume, volume: 0.4, channels: ["1": 0, "2": 0.7])
        let second = MicMuteWriteAhead.Entry(uid: "two", kind: .muteSwitch, volume: nil, channels: [:])
        XCTAssertTrue(store.append(first))
        XCTAssertTrue(store.append(second))
        let reopened = MicMuteWriteAhead(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), key: "pending")
        guard case let .valid(record) = reopened.load() else { return XCTFail("Missing recovery record") }
        XCTAssertEqual(record.entries, [first, second])
    }

    func testMicrophoneWriteAheadRejectsBadRecordsAndFailedSync() throws {
        let suite = "anchor.test.mic-write-ahead.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let entry = MicMuteWriteAhead.Entry(uid: "one", kind: .muteSwitch, volume: nil, channels: [:])
        let failed = MicMuteWriteAhead(defaults: defaults, key: "pending", synchronize: { false })
        XCTAssertFalse(failed.append(entry))
        defaults.set(Data("unreadable".utf8), forKey: "pending")
        let store = MicMuteWriteAhead(defaults: defaults, key: "pending")
        guard case .invalid = store.load() else { return XCTFail("Corrupt record was accepted") }
        XCTAssertFalse(store.append(entry))
        XCTAssertEqual(defaults.data(forKey: "pending"), Data("unreadable".utf8))
        defaults.set(["orphan": 0.5], forKey: DefaultsKey.micMuteSavedVolumes)
        defaults.set("unchanged", forKey: "unrelated")
        XCTAssertTrue(store.discardAfterUserCheck())
        XCTAssertTrue((defaults.dictionary(forKey: DefaultsKey.micMuteSavedVolumes) ?? [:]).isEmpty)
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "unchanged")
    }

    func testMicrophoneWriteAheadCheckpointAndUserResolution() throws {
        let suite = "anchor.test.mic-write-ahead.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MicMuteWriteAhead(defaults: defaults, key: "pending")
        let entry = MicMuteWriteAhead.Entry(uid: "one", kind: .volume, volume: 0.4, channels: ["1": 0.3])
        XCTAssertTrue(store.append(entry))
        let failed = MicMuteWriteAhead(defaults: defaults, key: "pending", synchronize: { false })
        XCTAssertFalse(failed.checkpoint(volumes: ["one": 0.4], channels: ["one": ["1": 0.3]], devices: ["one"]))
        guard case .valid = store.load() else { return XCTFail("Failed checkpoint lost the pending record") }
        XCTAssertTrue(store.checkpoint(volumes: ["one": 0.4, "other": 0.8],
                                       channels: ["one": ["1": 0.3], "other": ["1": 0.9]],
                                       devices: ["one", "other"]))
        guard case .none = store.load() else { return XCTFail("Checkpoint did not clear the record") }
        XCTAssertTrue(store.append(entry))
        defaults.set(true, forKey: DefaultsKey.micMuteActive)
        XCTAssertFalse(failed.discardAfterUserCheck())
        guard case .valid = store.load() else { return XCTFail("Failed resolution lost the pending record") }
        XCTAssertTrue(store.discardAfterUserCheck())
        XCTAssertEqual(defaults.stringArray(forKey: DefaultsKey.micMuteMutedDevices), ["other"])
        XCTAssertEqual(defaults.dictionary(forKey: DefaultsKey.micMuteSavedVolumes) as? [String: Double], ["other": 0.8])
        XCTAssertFalse(defaults.bool(forKey: DefaultsKey.micMuteActive))
        guard case .none = store.load() else { return XCTFail("Resolution did not clear the record") }
    }

    func testMicrophoneWriteAheadPrecedesDeviceWriteAndIsNotExported() throws {
        let suite = "anchor.test.mic-write-ahead.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MicMuteWriteAhead(defaults: defaults, key: "pending")
        let mic = MicMuteService.InputDevice(id: 1, uid: "owned")
        var writes = 0
        let backend = MicMuteService.MuteBackend(
            muteSwitch: { _ in .value(0) }, setMute: { _, _ in
                guard case let .valid(record) = store.load(), record.entries.map(\.uid) == ["owned"] else {
                    XCTFail("Device write began before the recovery record was saved")
                    return .failed
                }
                writes += 1
                return .confirmed
            }, isSilenced: { _ in false }, volume: { _ in nil }, channels: { _ in [:] },
            volumeSnapshotMatches: { _, _, _ in false }, setVolume: { _, _ in false },
            volumeMuteVerified: { _, _ in false }, isActiveNonAggregate: { _ in true },
            prepareWrite: { store.append($0) }, mayMute: { true })
        let outcome = MicMuteService.mute([mic], savedVolumes: [:], savedChannelVolumes: [:],
                                           mutedDevices: [], backend: backend)
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(store.checkpoint(volumes: outcome.savedVolumes, channels: outcome.savedChannelVolumes,
                                       devices: outcome.mutedDevices))
        XCTAssertFalse(SettingsBackupSupport.exportKeys().contains(DefaultsKey.micMuteWriteAhead))
    }

    func testMicrophoneVolumeWritesRecordOriginalAndRestoreLevelsFirst() throws {
        let suite = "anchor.test.mic-write-ahead.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MicMuteWriteAhead(defaults: defaults, key: "pending")
        let mic = MicMuteService.InputDevice(id: 1, uid: "owned")
        let channels = ["1": 0.3, "2": 0.6]
        let mute = MicMuteService.MuteBackend(
            muteSwitch: { _ in .unavailable }, setMute: { _, _ in .failed },
            isSilenced: { _ in false }, volume: { _ in 0.5 }, channels: { _ in channels },
            volumeSnapshotMatches: { _, _, _ in true }, setVolume: { _, _ in
                guard case let .valid(record) = store.load(), let entry = record.entries.last else {
                    XCTFail("No record before mute write"); return false
                }
                XCTAssertEqual(entry.kind, .volume)
                XCTAssertEqual(entry.volume, 0.5)
                XCTAssertEqual(entry.channels, channels)
                return true
            }, volumeMuteVerified: { _, _ in true }, isActiveNonAggregate: { _ in true },
            prepareWrite: { store.append($0) }, mayMute: { true })
        let muted = MicMuteService.mute([mic], savedVolumes: [:], savedChannelVolumes: [:],
                                        mutedDevices: [], backend: mute)
        XCTAssertTrue(store.checkpoint(volumes: muted.savedVolumes, channels: muted.savedChannelVolumes,
                                       devices: muted.mutedDevices))
        let restore = MicMuteService.RestoreBackend(
            muteSwitch: { _ in .unavailable }, setMute: { _, _ in false }, volume: { _ in 0 },
            setVolume: { _, _, _ in
                guard case let .valid(record) = store.load(), let entry = record.entries.last else {
                    XCTFail("No record before restore write"); return false
                }
                XCTAssertEqual(entry.kind, .restoreVolume)
                XCTAssertEqual(entry.volume, 0.5)
                XCTAssertEqual(entry.channels, channels)
                return true
            }, volumeRestoreVerified: { _, _ in true }, volumeRestoreMayWrite: { _, _ in true },
            prepareWrite: { store.append($0) })
        let restored = MicMuteService.unmute([mic], savedVolumes: muted.savedVolumes,
                                             savedChannelVolumes: muted.savedChannelVolumes,
                                             mutedDevices: muted.mutedDevices, legacyVolume: 0, backend: restore)
        XCTAssertTrue(restored.mutedDevices.isEmpty)
        XCTAssertTrue(store.checkpoint(volumes: restored.savedVolumes, channels: restored.savedChannelVolumes,
                                       devices: restored.mutedDevices))
    }

    func testMicrophoneMuteDoesNotWriteWhenRecoveryRecordFails() {
        let mic = MicMuteService.InputDevice(id: 1, uid: "owned")
        var writes = 0
        let backend = MicMuteService.MuteBackend(
            muteSwitch: { _ in .value(0) }, setMute: { _, _ in writes += 1; return .confirmed },
            isSilenced: { _ in false }, volume: { _ in 0.5 }, channels: { _ in [:] },
            volumeSnapshotMatches: { _, _, _ in true }, setVolume: { _, _ in writes += 1; return true },
            volumeMuteVerified: { _, _ in true }, isActiveNonAggregate: { _ in true }, prepareWrite: { _ in false }, mayMute: { true })
        let outcome = MicMuteService.mute([mic], savedVolumes: [:], savedChannelVolumes: [:],
                                           mutedDevices: [], backend: backend)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(outcome.recoveryBlocked)
    }

    func testMicrophoneRestoreDoesNotWriteWhenRecoveryRecordFails() {
        let mic = MicMuteService.InputDevice(id: 1, uid: "owned")
        var writes = 0
        let backend = MicMuteService.RestoreBackend(
            muteSwitch: { _ in .value(1) }, setMute: { _, _ in writes += 1; return true },
            volume: { _ in nil }, setVolume: { _, _, _ in writes += 1; return true },
            volumeRestoreVerified: { _, _ in false }, volumeRestoreMayWrite: { _, _ in false },
            prepareWrite: { _ in false })
        let outcome = MicMuteService.unmute([mic], savedVolumes: [:], savedChannelVolumes: [:],
                                             mutedDevices: ["owned"], legacyVolume: 0, backend: backend)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(outcome.recoveryBlocked)
    }

    func testMicrophoneSilenceRequiresEveryChannelWithoutMaster() {
        XCTAssertFalse(MicMuteSupport.volumeIsSilent(hasMaster: false, master: nil, channels: [0, 0.6]))
        XCTAssertTrue(MicMuteSupport.volumeIsSilent(hasMaster: false, master: nil, channels: [0, 0]))
        XCTAssertFalse(MicMuteSupport.volumeIsSilent(hasMaster: false, master: nil, channels: [0, nil]))
        XCTAssertFalse(MicMuteSupport.volumeIsSilent(hasMaster: false, master: nil, channels: []))
        XCTAssertTrue(MicMuteSupport.volumeIsSilent(hasMaster: true, master: 0, channels: [0.5]))
        XCTAssertFalse(MicMuteSupport.volumeIsSilent(hasMaster: true, master: nil, channels: [0]))
    }

    func testMicrophoneMuteReachesAudibleSecondChannelWithoutMaster() {
        let mic = MicMuteService.InputDevice(id: 1, uid: "stereo")
        var channels = ["1": 0.0, "2": 0.6]
        var writes = 0
        let backend = MicMuteService.MuteBackend(
            muteSwitch: { _ in .unavailable }, setMute: { _, _ in .failed },
            isSilenced: { _ in MicMuteSupport.volumeIsSilent(hasMaster: false, master: nil,
                                                              channels: [Float(channels["1"]!), Float(channels["2"]!)]) },
            volume: { _ in Float(channels["1"]!) }, channels: { _ in channels },
            volumeSnapshotMatches: { _, _, _ in true },
            setVolume: { _, _ in writes += 1; channels = ["1": 0, "2": 0]; return true },
            volumeMuteVerified: { _, _ in channels.values.allSatisfy { $0 == 0 } },
            isActiveNonAggregate: { _ in true }, prepareWrite: { _ in true }, mayMute: { true })
        let result = MicMuteService.mute([mic], savedVolumes: [:], savedChannelVolumes: [:],
                                         mutedDevices: [], backend: backend)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(result.mutedDevices, ["stereo"])
        XCTAssertEqual(result.savedChannelVolumes["stereo"], ["1": 0, "2": 0.6])
        XCTAssertFalse(result.failed)
    }

    func testMicrophoneSavedChannelsIncludeDeliberateSilence() {
        XCTAssertTrue(MicMuteSupport.shouldSaveChannelVolume(0))
        XCTAssertTrue(MicMuteSupport.shouldSaveChannelVolume(0.5))
        XCTAssertTrue(MicMuteSupport.shouldSaveChannelVolume(1))
        XCTAssertFalse(MicMuteSupport.shouldSaveChannelVolume(-0.1))
        XCTAssertFalse(MicMuteSupport.shouldSaveChannelVolume(1.1))
        XCTAssertFalse(MicMuteSupport.shouldSaveChannelVolume(.nan))
        XCTAssertFalse(MicMuteSupport.shouldSaveChannelVolume(.infinity))
    }

    private final class Engine {
        var memory = Data(count: 4 * 1024 * 1024)
        var running = true
    }

    func testMicrophoneRecoveryTargetsOnlyRecordedDevicesWhileDisabled() {
        var claims = ["disconnected"]
        var muted = ["user-muted": true, "disconnected": true]
        XCTAssertTrue(MicMuteSupport.needsRecoveryAtLaunch(featureAvailable: false, recorded: claims))
        XCTAssertFalse(MicMuteSupport.needsRecoveryAtLaunch(featureAvailable: true, recorded: claims))
        XCTAssertFalse(MicMuteSupport.needsRecoveryAtLaunch(featureAvailable: false, recorded: []))
        XCTAssertTrue(MicMuteSupport.needsDeviceListeners(featureAvailable: false, wantsMute: false, hasClaims: true))
        let firstPresent = ["user-muted"]
        let firstTargets = MicMuteSupport.restoreTargets(recorded: claims, present: firstPresent)
        XCTAssertTrue(firstTargets.isEmpty)
        claims = MicMuteSupport.absentClaims(recorded: claims, present: firstPresent)
        XCTAssertEqual(claims, ["disconnected"])
        let reconnected = ["user-muted", "disconnected"]
        let targets = MicMuteSupport.restoreTargets(recorded: claims, present: reconnected)
        for target in targets { muted[target] = false }
        claims = MicMuteSupport.absentClaims(recorded: claims, present: reconnected)
        XCTAssertEqual(muted["user-muted"], true, "A device muted by the user must remain muted")
        XCTAssertEqual(muted["disconnected"], false)
        XCTAssertTrue(claims.isEmpty)
        XCTAssertFalse(MicMuteSupport.needsDeviceListeners(featureAvailable: false, wantsMute: false, hasClaims: false))
        XCTAssertFalse(MicMuteSupport.needsDeviceListeners(featureAvailable: false, wantsMute: true, hasClaims: false))
    }

    func testMicrophoneRestoreRetainsFailedClaimsAndRetriesOnlyOwnedDevices() {
        let switchMic = MicMuteService.InputDevice(id: 1, uid: "switch")
        let volumeMic = MicMuteService.InputDevice(id: 2, uid: "volume")
        let userMic = MicMuteService.InputDevice(id: 3, uid: "user")
        let returningMic = MicMuteService.InputDevice(id: 4, uid: "away")
        var switches: [UInt32: UInt32] = [1: 1, 3: 1, 4: 1]
        var volumes: [UInt32: Float] = [2: 0]
        var failVolume = true
        var writes: [UInt32] = []
        var restoredChannels: [String: Double] = [:]
        let backend = MicMuteService.RestoreBackend(
            muteSwitch: { switches[$0].map { .value($0) } ?? .unavailable },
            setMute: { muted, id in
                writes.append(id)
                switches[id] = muted ? 1 : 0
                return true
            },
            volume: { volumes[$0] },
            setVolume: { level, id, channels in
                writes.append(id)
                guard !failVolume else { return false }
                volumes[id] = level
                restoredChannels = channels
                return true
            },
            volumeRestoreVerified: { _, channels in restoredChannels == channels },
            volumeRestoreMayWrite: { _, _ in true }, prepareWrite: { _ in true })
        let initial = MicMuteService.unmute(
            [switchMic, volumeMic, userMic], savedVolumes: ["volume": 0.42],
            savedChannelVolumes: ["volume": ["1": 0, "2": 0.5]],
            mutedDevices: ["switch", "volume", "away"], legacyVolume: 0.75, backend: backend)
        XCTAssertTrue(initial.applied)
        XCTAssertTrue(initial.failed)
        XCTAssertEqual(Set(initial.mutedDevices), Set(["volume", "away"]))
        XCTAssertEqual(initial.savedVolumes["volume"], 0.42)
        XCTAssertEqual(switches[3], 1, "The user's unrelated mute must never be changed")
        XCTAssertFalse(writes.contains(3))

        failVolume = false
        let retried = MicMuteService.unmute(
            [switchMic, volumeMic, userMic, returningMic], savedVolumes: initial.savedVolumes,
            savedChannelVolumes: initial.savedChannelVolumes, mutedDevices: initial.mutedDevices,
            legacyVolume: 0.75, backend: backend)
        XCTAssertTrue(retried.applied)
        XCTAssertFalse(retried.failed)
        XCTAssertTrue(retried.mutedDevices.isEmpty)
        XCTAssertEqual(volumes[2]!, 0.42, accuracy: 0.0001)
        XCTAssertEqual(restoredChannels, ["1": 0, "2": 0.5])
        XCTAssertEqual(switches[4], 0)
        XCTAssertEqual(switches[3], 1)
        XCTAssertFalse(writes.contains(3))
    }

    func testMicrophonePartialChannelRestoreRetainsSavedLevels() {
        let mic = MicMuteService.InputDevice(id: 1, uid: "owned")
        var firstVolume: Float = 0
        var channels = ["1": 0.0, "2": 0.0]
        var writes = 0
        let backend = MicMuteService.RestoreBackend(
            muteSwitch: { _ in .unavailable }, setMute: { _, _ in false },
            volume: { _ in firstVolume },
            setVolume: { _, _, _ in
                writes += 1
                firstVolume = 0.4
                channels["1"] = 0.4
                return true // A driver reports success despite channel 2 failing.
            },
            volumeRestoreVerified: { _, expected in channels == expected },
            volumeRestoreMayWrite: { _, _ in channels.values.allSatisfy { $0 <= 0.01 } }, prepareWrite: { _ in true })
        let initial = MicMuteService.unmute(
            [mic], savedVolumes: ["owned": 0.4],
            savedChannelVolumes: ["owned": ["1": 0.4, "2": 0.6]],
            mutedDevices: ["owned"], legacyVolume: 0, backend: backend)
        XCTAssertEqual(initial.mutedDevices, ["owned"])
        XCTAssertEqual(initial.savedChannelVolumes["owned"], ["1": 0.4, "2": 0.6])
        XCTAssertTrue(initial.failed)
        let retried = MicMuteService.unmute(
            [mic], savedVolumes: initial.savedVolumes, savedChannelVolumes: initial.savedChannelVolumes,
            mutedDevices: initial.mutedDevices, legacyVolume: 0, backend: backend)
        XCTAssertEqual(retried.mutedDevices, ["owned"])
        XCTAssertEqual(writes, 1, "Do not overwrite an audible level that may have been changed by the user")
        channels["2"] = 0.6
        let verified = MicMuteService.unmute(
            [mic], savedVolumes: retried.savedVolumes, savedChannelVolumes: retried.savedChannelVolumes,
            mutedDevices: retried.mutedDevices, legacyVolume: 0, backend: backend)
        XCTAssertTrue(verified.mutedDevices.isEmpty)
    }

    func testMicrophoneRestoreDoesNotOverwriteOtherChannelOrUserMute() {
        let saved = ["1": 0.5, "2": 0.6]
        XCTAssertTrue(MicMuteSupport.volumeRestoreMayWrite(elements: [(0, 0), (1, 0), (2, 0)], channels: saved))
        XCTAssertFalse(MicMuteSupport.volumeRestoreMayWrite(elements: [(0, 0), (1, 0), (2, 0.4)], channels: saved))
        XCTAssertFalse(MicMuteSupport.volumeRestoreMayWrite(elements: [(1, 0), (2, nil)], channels: saved))
        XCTAssertFalse(MicMuteSupport.volumeRestoreMayWrite(elements: [(1, 0), (2, 0)], channels: ["1": 0.5]))
        XCTAssertFalse(MicMuteSupport.volumeRestoreMayWrite(elements: [], channels: saved))
        let channelMic = MicMuteService.InputDevice(id: 1, uid: "channel")
        let switchMic = MicMuteService.InputDevice(id: 2, uid: "switch")
        var volumeWrites = 0
        var switchWrites = 0
        let backend = MicMuteService.RestoreBackend(
            muteSwitch: { $0 == 2 ? .value(1) : .unavailable },
            setMute: { _, _ in switchWrites += 1; return true },
            volume: { _ in 0 },
            setVolume: { _, _, _ in volumeWrites += 1; return true },
            volumeRestoreVerified: { _, _ in false },
            volumeRestoreMayWrite: { _, _ in false }, prepareWrite: { _ in true })
        let result = MicMuteService.unmute(
            [channelMic, switchMic], savedVolumes: ["channel": 0.5, "switch": 0.5],
            savedChannelVolumes: ["channel": ["1": 0.5, "2": 0.6]],
            mutedDevices: ["channel", "switch"], legacyVolume: 0, backend: backend)
        XCTAssertEqual(Set(result.mutedDevices), Set(["channel", "switch"]))
        XCTAssertEqual(volumeWrites, 0)
        XCTAssertEqual(switchWrites, 0)
        XCTAssertTrue(result.failed)
    }

    func testMicrophoneMuteKeepsUnconfirmedWritesAndSkipsUnknownOwnership() {
        let alreadyMuted = MicMuteService.InputDevice(id: 1, uid: "user")
        let unreadable = MicMuteService.InputDevice(id: 2, uid: "unknown")
        let uncertain = MicMuteService.InputDevice(id: 3, uid: "uncertain")
        var writes: [UInt32] = []
        let backend = MicMuteService.MuteBackend(
            muteSwitch: { id in id == 1 ? .value(1) : (id == 2 ? .unreadable : .value(0)) },
            setMute: { _, id in writes.append(id); return .unconfirmed },
            isSilenced: { _ in false }, volume: { _ in 0.5 }, channels: { _ in [:] },
            volumeSnapshotMatches: { _, _, _ in true },
            setVolume: { _, _ in XCTFail("Do not fall back after an uncertain switch write"); return true },
            volumeMuteVerified: { _, _ in true },
            isActiveNonAggregate: { _ in true }, prepareWrite: { _ in true }, mayMute: { true })
        let result = MicMuteService.mute([alreadyMuted, unreadable, uncertain], savedVolumes: [:],
                                          savedChannelVolumes: [:], mutedDevices: [], backend: backend)
        XCTAssertEqual(writes, [3])
        XCTAssertEqual(result.mutedDevices, ["uncertain"])
        XCTAssertTrue(result.applied)
        XCTAssertTrue(result.failed)
    }

    func testMicrophonePartialMuteRetainsOriginalLevelsAndClaim() {
        let mic = MicMuteService.InputDevice(id: 1, uid: "owned")
        var channelLevels = ["1": 0.4, "2": 0.6]
        let backend = MicMuteService.MuteBackend(
            muteSwitch: { _ in .unavailable }, setMute: { _, _ in .failed },
            isSilenced: { _ in false }, volume: { _ in 0.5 }, channels: { _ in channelLevels },
            volumeSnapshotMatches: { _, _, _ in true },
            setVolume: { _, _ in channelLevels["1"] = 0; return false },
            volumeMuteVerified: { _, _ in false }, isActiveNonAggregate: { _ in true }, prepareWrite: { _ in true }, mayMute: { true })
        let first = MicMuteService.mute([mic], savedVolumes: [:], savedChannelVolumes: [:],
                                        mutedDevices: [], backend: backend)
        XCTAssertEqual(first.mutedDevices, ["owned"])
        XCTAssertEqual(first.savedVolumes["owned"], 0.5)
        XCTAssertEqual(first.savedChannelVolumes["owned"], ["1": 0.4, "2": 0.6])
        XCTAssertTrue(first.applied)
        XCTAssertTrue(first.failed)
        let repeated = MicMuteService.mute([mic], savedVolumes: first.savedVolumes,
                                           savedChannelVolumes: first.savedChannelVolumes,
                                           mutedDevices: first.mutedDevices, backend: backend)
        XCTAssertEqual(repeated.savedChannelVolumes["owned"], ["1": 0.4, "2": 0.6])
        XCTAssertEqual(repeated.mutedDevices, ["owned"])
    }

    func testMicrophoneMuteSnapshotRequiresAllReadableStableElements() {
        let channels = ["1": 0.4, "2": 0.6]
        XCTAssertTrue(MicMuteSupport.volumeSnapshotMatches(elements: [(0, 0.5), (1, 0.4), (2, 0.6)],
                                                           volume: 0.5, channels: channels))
        XCTAssertFalse(MicMuteSupport.volumeSnapshotMatches(elements: [(0, 0.5), (1, nil)],
                                                            volume: 0.5, channels: channels))
        XCTAssertFalse(MicMuteSupport.volumeSnapshotMatches(elements: [(1, 0.4), (2, 0.8)],
                                                            volume: 0.4, channels: channels))
        XCTAssertFalse(MicMuteSupport.volumeSnapshotMatches(elements: [(1, 0.4), (2, 0.6)],
                                                            volume: 0.4, channels: ["1": 0.4]))
    }

    func testMicrophoneRestoreRetainsClaimWhenMuteSwitchIsUnreadable() {
        let mic = MicMuteService.InputDevice(id: 1, uid: "owned")
        var state = MicMuteService.MuteSwitchState.value(1)
        var writes = 0
        let backend = MicMuteService.RestoreBackend(
            muteSwitch: { _ in state },
            setMute: { _, _ in writes += 1; state = .unreadable; return false },
            volume: { _ in 0.5 },
            setVolume: { _, _, _ in XCTFail("Do not infer switch state from volume"); return true },
            volumeRestoreVerified: { _, _ in XCTFail("Do not infer switch state from volume"); return false },
            volumeRestoreMayWrite: { _, _ in XCTFail("Do not infer switch state from volume"); return false },
            prepareWrite: { _ in true })
        let first = MicMuteService.unmute([mic], savedVolumes: [:], savedChannelVolumes: [:],
                                          mutedDevices: ["owned"], legacyVolume: 0, backend: backend)
        XCTAssertEqual(first.mutedDevices, ["owned"])
        XCTAssertTrue(first.failed)
        let unreadable = MicMuteService.unmute([mic], savedVolumes: first.savedVolumes,
                                               savedChannelVolumes: first.savedChannelVolumes,
                                               mutedDevices: first.mutedDevices, legacyVolume: 0,
                                               backend: backend)
        XCTAssertEqual(unreadable.mutedDevices, ["owned"])
        XCTAssertTrue(unreadable.failed)
        XCTAssertEqual(writes, 1)
        state = .value(0)
        let recovered = MicMuteService.unmute([mic], savedVolumes: unreadable.savedVolumes,
                                              savedChannelVolumes: unreadable.savedChannelVolumes,
                                              mutedDevices: unreadable.mutedDevices, legacyVolume: 0,
                                              backend: backend)
        XCTAssertTrue(recovered.mutedDevices.isEmpty)
        XCTAssertFalse(recovered.failed)
    }

    func testAutomaticMicrophoneRecoveryNeverInfersLegacyOwnership() {
        XCTAssertTrue(MicMuteSupport.hasUntrackedActiveMute(active: true, recorded: nil))
        XCTAssertFalse(MicMuteSupport.hasUntrackedActiveMute(active: true, recorded: []))
        let automatic = MicMuteSupport.claimsForSweep(recorded: nil, muted: false, explicitUnmute: false)
        XCTAssertEqual(automatic, [])
        XCTAssertTrue(MicMuteSupport.restoreTargets(recorded: automatic, present: ["user-muted"]).isEmpty)
        let explicit = MicMuteSupport.claimsForSweep(recorded: nil, muted: false, explicitUnmute: true)
        XCTAssertNil(explicit, "Explicit legacy unmute retains its existing fallback")
        XCTAssertEqual(MicMuteSupport.restoreTargets(recorded: explicit, present: ["mic"]), ["mic"])
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
        XCTAssertNotNil(CaptureDisablementGuard.reason(for: .screenshot, screenshotPreview: true))
        XCTAssertNotNil(CaptureDisablementGuard.reason(for: .screenshot, screenshotWork: true))
        XCTAssertNil(CaptureDisablementGuard.reason(for: .mediaTools, screenshotPreview: true, screenshotWork: true))
        XCTAssertNil(CaptureDisablementGuard.reason(for: .screenOCR, screenshotEditor: true, screenshotWork: true))
        XCTAssertNil(CaptureDisablementGuard.reason(for: .colorPicker, screenshotPreview: true))
        for feature: AppFeature in [.screenshot, .screenRecorder, .colorPicker, .screenOCR] {
            XCTAssertNotNil(CaptureDisablementGuard.reason(for: feature, sharedCapture: true))
            XCTAssertNotNil(CaptureDisablementGuard.sharedCaptureReason(for: feature, sharedCapture: true, enabling: true))
        }
        XCTAssertNil(CaptureDisablementGuard.reason(for: .mediaTools, sharedCapture: true))
        XCTAssertNil(CaptureDisablementGuard.sharedCaptureReason(for: .mediaTools, sharedCapture: true, enabling: true))
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

    func testConfirmedSelectionIsProtectedWithoutOpeningCaptureUI() throws {
        let suite = "anchor.test.capture-guard.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ScreenshotSelectionController(freeze: false, includePointer: false,
                                                       showLastRegion: false, defaults: defaults)
        XCTAssertFalse(ScreenCaptureService.hasCommittedCapture(nil))
        XCTAssertFalse(ScreenCaptureService.hasCommittedCapture(controller))
        controller.markCapturePending()
        XCTAssertTrue(ScreenCaptureService.hasCommittedCapture(controller))
        XCTAssertNotNil(CaptureDisablementGuard.reason(for: .screenOCR,
                                                        sharedCapture: ScreenCaptureService.hasCommittedCapture(controller)))
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

    func testPastePlainRejectsOldSessionAndChangedTarget() throws {
        let gate = ClipboardPresentationGate()
        gate.update(available: true)
        let ticket = try XCTUnwrap(gate.capture(currentlyAvailable: true))
        let accept = { (ticket: UUID) in gate.accepts(ticket, currentlyAvailable: true) }
        XCTAssertTrue(PastePlainService.canPaste(ticket: ticket, target: 10, accepts: accept, frontmost: { 10 }))
        XCTAssertFalse(PastePlainService.canPaste(ticket: ticket, target: 10, accepts: accept, frontmost: { 11 }))
        gate.update(available: false)
        gate.update(available: true)
        XCTAssertFalse(PastePlainService.canPaste(ticket: ticket, target: 10, accepts: accept, frontmost: { 10 }))
    }

    func testTransientPasteCancellationFinishesCleanupWithoutPosting() throws {
        var allowed = true
        var scheduled: (() -> Void)?
        var posted = false
        var failed = false
        var cleanedUp = false
        TransientPaste.postPasteWhenModifiersReleased(
            attempt: 0, shouldPost: { allowed }, willPost: nil, didPost: nil,
            didFail: { failed = true }, modifiersHeld: { false },
            schedule: { _, work in scheduled = work },
            post: { _, _ in posted = true },
            completion: { cleanedUp = true })
        allowed = false
        try XCTUnwrap(scheduled)()
        XCTAssertFalse(posted)
        XCTAssertTrue(failed)
        XCTAssertTrue(cleanedUp, "The temporary clipboard must still be scheduled for restoration")
    }

    func testTransientPastePostsAndCompletesWhenAllowed() throws {
        var scheduled: (() -> Void)?
        var willPost = false
        var didPost = false
        var completed = false
        TransientPaste.postPasteWhenModifiersReleased(
            attempt: 0, shouldPost: { true }, willPost: { willPost = true },
            didPost: { didPost = true }, didFail: { XCTFail("Unexpected failure") },
            modifiersHeld: { false }, schedule: { _, work in scheduled = work },
            post: { before, finish in before?(); finish(true) },
            completion: { completed = true })
        try XCTUnwrap(scheduled)()
        XCTAssertTrue(willPost)
        XCTAssertTrue(didPost)
        XCTAssertTrue(completed)
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
