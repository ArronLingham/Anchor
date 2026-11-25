// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Foundation

/// Wipes the system pasteboard on four independent, opt-in triggers: a delay
/// after the last copy, computer sleep, display sleep, and screen lock.
/// Independent of clipboard history: someone who keeps no history at all is
/// exactly the person who wants a copied password gone.
///
/// Saved history entries are never touched, only the pasteboard.
final class ClipboardAutoClearService {
    static let shared = ClipboardAutoClearService()

    private var timer: Timer?
    /// The change count last acted on, and when it first appeared. The date is
    /// wall clock rather than a count of ticks: timers do not fire while the
    /// Mac sleeps, so a machine asleep past the delay clears on the first tick
    /// after waking instead of starting the wait over.
    private var lastChangeCount = 0
    private var lastChangeDate = Date()
    /// The count our own clear produced, so a clear is never mistaken for a copy.
    private var lastClearedChangeCount = -1
    /// Only ever one read in flight, mirroring the history poll: while a
    /// password prompt holds the pasteboard server a read can take seconds, and
    /// letting ticks pile up would spawn a thread each time.
    private var readInFlight = false
    /// Each read carries a token, so one that wedged behind a password prompt
    /// can be abandoned without a stale completion ever landing.
    private var readGeneration = 0
    private var needsDelayBaseline = true
    // Read and written only on the pasteboard lane.
    private var lastPerformedClearCount: Int?
    private let configurationLock = NSLock()
    private var configurationGeneration = 0

    private struct Observation {
        let token: NSObjectProtocol
        let id: UUID
    }

    private var observers: [String: Observation] = [:]
    /// The app is not sandboxed, so the lock notification is delivered. There is
    /// no AppKit constant for it.
    private static let screenLockNotification = Notification.Name("com.apple.screenIsLocked")

    private init() {}

    func syncWithPreferences() {
        UtilityWorkspace.shared.prepareOwnership()
        configurationLock.lock()
        configurationGeneration &+= 1
        configurationLock.unlock()
        let defaults = UtilityPreferences.standard
        let isAvailable = AppFeature.clipboardHistory.isAvailable
        if isAvailable, defaults.bool(forKey: DefaultsKey.clipboardAutoClearOnDelay) {
            startTimer()
        } else {
            stopTimer()
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        syncObserver(isWanted: isAvailable && defaults.bool(forKey: DefaultsKey.clipboardAutoClearOnSleep),
                     preferenceKey: DefaultsKey.clipboardAutoClearOnSleep,
                     name: NSWorkspace.willSleepNotification,
                     center: workspaceCenter)
        syncObserver(isWanted: isAvailable && defaults.bool(forKey: DefaultsKey.clipboardAutoClearOnDisplaySleep),
                     preferenceKey: DefaultsKey.clipboardAutoClearOnDisplaySleep,
                     name: NSWorkspace.screensDidSleepNotification,
                     center: workspaceCenter)
        syncObserver(isWanted: isAvailable && defaults.bool(forKey: DefaultsKey.clipboardAutoClearOnScreenLock),
                     preferenceKey: DefaultsKey.clipboardAutoClearOnScreenLock,
                     name: Self.screenLockNotification,
                     center: DistributedNotificationCenter.default())
    }

    /// Each trigger holds its own observer, so it works with the others (and
    /// with the delay) switched off.
    private func syncObserver(isWanted: Bool, preferenceKey: String,
                              name: Notification.Name, center: NotificationCenter) {
        if isWanted {
            guard observers[preferenceKey] == nil else { return }
            let id = UUID()
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.observers[preferenceKey]?.id == id else { return }
                self.clearNow(triggerPreferenceKey: preferenceKey, generation: self.currentGeneration())
            }
            observers[preferenceKey] = Observation(token: token, id: id)
        } else if let observer = observers.removeValue(forKey: preferenceKey) {
            center.removeObserver(observer.token)
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        needsDelayBaseline = true
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, self.timer === timer else { return }
            self.tick()
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        readGeneration &+= 1
    }

    private func currentGeneration() -> Int {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        return configurationGeneration
    }

    private func permitsClear(_ key: String, generation: Int) -> Bool {
        ClipboardAutoClearSupport.clearIsAuthorized(
            enqueuedGeneration: generation,
            currentGeneration: currentGeneration(),
            featureIsAvailable: AppFeature.clipboardHistory.isAvailable,
            triggerIsEnabled: UtilityPreferences.standard.bool(forKey: key))
    }

    private func tick() {
        let key = DefaultsKey.clipboardAutoClearOnDelay
        let generation = currentGeneration()
        guard permitsClear(key, generation: generation) else { return }
        let delay = Defaults.sanitizedClipboardAutoClearDelay(
            UtilityPreferences.standard.integer(forKey: DefaultsKey.clipboardAutoClearDelay))
        readChangeCount { [weak self] count in
            guard let self, self.permitsClear(key, generation: generation) else { return }
            // Give existing clipboard content the full delay when we start.
            if self.needsDelayBaseline {
                self.lastChangeCount = count
                self.lastChangeDate = Date()
                self.needsDelayBaseline = false
                return
            }
            switch ClipboardAutoClearSupport.decide(changeCount: count,
                                                    lastChangeCount: self.lastChangeCount,
                                                    lastClearedChangeCount: self.lastClearedChangeCount,
                                                    lastChangeDate: self.lastChangeDate,
                                                    now: Date(),
                                                    delay: TimeInterval(delay)) {
            case .noteChange:
                self.lastChangeCount = count
                self.lastChangeDate = Date()
            case .clear:
                self.clearNow(expecting: count, triggerPreferenceKey: key, generation: generation)
            case .wait:
                break
            }
        }
    }

    /// Reads the change count on the shared pasteboard lane and answers on the
    /// main thread. Never reads on the main thread: a blocked main thread stalls
    /// every event tap with it, which is what froze typing system wide in #189.
    private func readChangeCount(_ completion: @escaping (Int) -> Void) {
        guard !readInFlight else { return }
        readInFlight = true
        readGeneration &+= 1
        let generation = readGeneration
        GeneralPasteboardAccess.shared.async(timeout: 5, { _ in
            NSPasteboard.general.changeCount
        }, then: { [weak self] count in
            guard let self, let count, self.readGeneration == generation else { return }
            completion(count)
        }, didFinish: { [weak self] _ in
            // Even after timeout or a toggle, one actual read owns this slot.
            self?.readInFlight = false
        })
    }

    /// Clears the pasteboard and records the count the clear produced, which is
    /// what keeps the delay from reading its own clear as fresh content.
    /// `expectedChangeCount` lets a caller clear only if the pasteboard state
    /// still matches; leaving it nil means clear whatever is on the pasteboard
    /// right now, which is what the event triggers want.
    private func clearNow(expecting expectedChangeCount: Int? = nil,
                          triggerPreferenceKey: String, generation: Int) {
        guard permitsClear(triggerPreferenceKey, generation: generation) else { return }
        GeneralPasteboardAccess.shared.async { [weak self] in
            guard let self, self.permitsClear(triggerPreferenceKey, generation: generation) else { return }
            let pasteboard = NSPasteboard.general
            let changeCount = pasteboard.changeCount
            // Screen lock and display sleep can arrive together.
            guard changeCount != self.lastPerformedClearCount,
                  expectedChangeCount == nil || changeCount == expectedChangeCount,
                  self.permitsClear(triggerPreferenceKey, generation: generation) else { return }
            let count = pasteboard.clearContents()
            self.lastPerformedClearCount = count
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastChangeCount = count
                self.lastClearedChangeCount = count
                self.lastChangeDate = Date()
                // Keeps the history poll from reading the empty pasteboard as
                // a copy, the same handshake a history paste performs.
                ClipboardHistoryService.existing?.ignoreNextChange(upTo: count)
                ClipboardHistoryService.existing?.pasteboardWasCleared()
            }
        }
    }
}
