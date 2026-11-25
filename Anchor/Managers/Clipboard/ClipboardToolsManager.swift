/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Combine
import Defaults
import Foundation
import os

/// Three small clipboard tools that share one owner because they all key off
/// the same pasteboard and would otherwise each need their own observer.
///
/// - **Paste as plain text** — strips formatting from what you paste while
///   leaving the original on the pasteboard.
/// - **Clean URL** — removes tracking parameters from copied links.
/// - **Auto-clear** — empties the pasteboard a set time after a copy, and on
///   sleep / display sleep / screen lock.
///
/// ## Cost
///
/// Nothing polls. Auto-clear arms a single one-shot timer per copy and only
/// while the feature is on; the sleep and lock triggers are `NSWorkspace`
/// notifications, registered only when enabled. Clean URL runs inside the
/// existing `ClipboardManager` poll — it adds no timer of its own. With all
/// three off, this object registers nothing and does nothing.
@MainActor
final class ClipboardToolsManager: ObservableObject {
    static let shared = ClipboardToolsManager()

    private var clearTimer: Timer?
    private let delayEpoch = OSAllocatedUnfairLock(initialState: UUID())
    private let triggerEpoch = OSAllocatedUnfairLock(initialState: UUID())
    private var observers: [SystemClearTrigger: SystemClearObservation] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private weak var watchedClipboard: ClipboardManager?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        Defaults.publisher(.autoClearClipboardOnLock, options: [])
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self, triggerEpoch] _ in
                triggerEpoch.withLock { $0 = UUID() }
                DispatchQueue.main.async { self?.syncSystemTriggers() }
            }
            .store(in: &cancellables)

        Defaults.publisher(.autoClearClipboardEnabled, options: [])
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self, delayEpoch] _ in
                delayEpoch.withLock { $0 = UUID() }
                DispatchQueue.main.async { self?.syncPasteboardWatch() }
            }
            .store(in: &cancellables)

        // Both URL cleaning and auto-clear observe copies, and the only thing
        // that watches the pasteboard is `ClipboardManager`'s poll — which
        // starts lazily, when the clipboard panel or a clipboard view is first
        // opened. Without this, enabling either tool appeared to do nothing
        // until the user happened to open the clipboard.
        //
        // Deliberately reusing that poll rather than adding a second one: it is
        // already parked on sleep/lock by `SystemActivityGate`, and a second
        // pasteboard watcher would double the cost for no benefit.
        for publisher in [
            Defaults.publisher(.enableClipboardManager).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.autoCleanCopiedURLs).map { _ in () }.eraseToAnyPublisher(),
        ] {
            publisher
                .sink { [weak self] in
                    Task { @MainActor in self?.syncPasteboardWatch() }
                }
                .store(in: &cancellables)
        }

        syncSystemTriggers()
        syncPasteboardWatch()
    }

    /// History and the clipboard tools share one watcher. Turning off one
    /// consumer must not stop the others, or keep collecting history for them.
    func syncPasteboardWatch() {
        if !usesNativeDelay || timerEpoch != delayEpoch.withLock({ $0 }) {
            clearTimer?.invalidate()
            clearTimer = nil
            timerEpoch = nil
        }
        let needsWatch = ClipboardCapturePolicy.needsWatcher(
            history: Defaults[.enableClipboardManager], cleanURLs: Defaults[.autoCleanCopiedURLs],
            autoClear: usesNativeDelay)
        if needsWatch {
            let clipboard = ClipboardManager.shared
            watchedClipboard = clipboard
            clipboard.startMonitoring()
        } else {
            watchedClipboard?.stopMonitoring()
            watchedClipboard = nil
        }
    }

    // MARK: - Paste as plain text

    /// Pastes the pasteboard's text with all formatting removed.
    ///
    /// Rather than mutating the real pasteboard and putting it back — which
    /// races anything else reading it — this reuses `TextInjector`, which
    /// already snapshots the pasteboard, writes, synthesises ⌘V and restores.
    /// That path is the one dictation uses, so it is already proven against
    /// Electron apps and terminals where the accessibility route fails.
    func pasteAsPlainText() async {
        let pasteboard = NSPasteboard.general
        guard let text = plainText(from: pasteboard), !text.isEmpty else {
            NSSound.beep()
            return
        }
        do {
            try await TextInjector.insert(text)
        } catch {
            NSLog("⚠️ Paste as plain text failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    /// The best plain-text rendering available on the pasteboard.
    ///
    /// `.string` is tried first because it is what most apps write alongside
    /// their rich flavour. RTF is decoded only as a fallback, for the apps that
    /// write RTF and nothing else.
    private func plainText(from pasteboard: NSPasteboard) -> String? {
        if let direct = pasteboard.string(forType: .string), !direct.isEmpty {
            return direct
        }
        if let rtf = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            return attributed.string
        }
        if let html = pasteboard.data(forType: .html),
           let attributed = NSAttributedString(html: html, documentAttributes: nil) {
            return attributed.string
        }
        return nil
    }

    // MARK: - Clean URL

    /// Query parameters stripped from copied links.
    ///
    /// Deliberately a fixed list of known-tracking names rather than a
    /// heuristic: guessing wrongly breaks real links, and a link that silently
    /// stops working is far worse than one that keeps a stray parameter. `utm_`
    /// is matched by prefix because the family is open-ended.
    private static let trackingPrefixes = ["utm_"]
    private static let trackingParameters: Set<String> = [
        // Google / general analytics
        "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "_ga", "_gl",
        // Meta
        "fbclid", "fb_action_ids", "fb_action_types", "fb_source", "fb_ref",
        // Microsoft / Yahoo / Yandex
        "msclkid", "yclid", "_openstat",
        // Mail and campaign tools
        "mc_cid", "mc_eid", "mkt_tok", "vero_conv", "vero_id", "oly_anon_id",
        "oly_enc_id", "hsa_cam", "hsa_grp", "hsa_ad", "hsa_src", "hsa_tgt",
        "hsa_kw", "hsa_mt", "hsa_net", "hsa_ver", "_hsenc", "_hsmi",
        // Social / referral
        "igshid", "igsh", "twclid", "ttclid", "li_fat_id", "s_kwcid",
        "ref_src", "ref_url", "spm", "scm",
    ]

    /// Returns `url` with tracking parameters removed, or `nil` when nothing
    /// changed — so callers can skip rewriting the pasteboard needlessly.
    static func cleaned(urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let items = components.queryItems, !items.isEmpty
        else { return nil }

        let kept = items.filter { item in
            let name = item.name.lowercased()
            if trackingParameters.contains(name) { return false }
            if trackingPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
            return true
        }
        guard kept.count != items.count else { return nil }

        var cleaned = components
        // An empty array still renders a trailing "?", so drop it entirely.
        cleaned.queryItems = kept.isEmpty ? nil : kept
        guard let result = cleaned.string, result != urlString else { return nil }
        return result
    }

    /// Called by `ClipboardManager` when it observes a new pasteboard string.
    /// Returns true when the pasteboard was rewritten.
    @discardableResult
    func cleanURLIfNeeded(_ candidate: String) -> Bool {
        guard Defaults[.autoCleanCopiedURLs] else { return false }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only touch things that are unambiguously a single web URL. A block of
        // prose that happens to contain a link is left alone.
        guard trimmed.count == candidate.trimmingCharacters(in: .whitespacesAndNewlines).count,
              !trimmed.contains(" "), !trimmed.contains("\n"),
              trimmed.lowercased().hasPrefix("http"),
              let cleaned = Self.cleaned(urlString: trimmed)
        else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(cleaned, forType: .string)
        ClipboardManager.shared.ignoreChangeCount(pasteboard.changeCount)
        return true
    }

    /// Cleans whatever URL is on the pasteboard right now, on demand.
    func cleanPasteboardURLNow() {
        let pasteboard = NSPasteboard.general
        guard let current = pasteboard.string(forType: .string),
              let cleaned = Self.cleaned(
                urlString: current.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            NSSound.beep()
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(cleaned, forType: .string)
        ClipboardManager.shared.ignoreChangeCount(pasteboard.changeCount)
    }

    // MARK: - Auto clear

    private enum SystemClearTrigger: String, CaseIterable {
        case sleep = "clipboardAutoClearSleep"
        case displaySleep = "clipboardAutoClearDisplaySleep"
        case lock = "clipboardAutoClearLock"

        var name: Notification.Name {
            switch self {
            case .sleep: NSWorkspace.willSleepNotification
            case .displaySleep: NSWorkspace.screensDidSleepNotification
            case .lock: Notification.Name("com.apple.screenIsLocked")
            }
        }

        var center: NotificationCenter {
            self == .lock ? DistributedNotificationCenter.default() : NSWorkspace.shared.notificationCenter
        }
    }

    private struct SystemClearObservation {
        let token: NSObjectProtocol
        let id: UUID
        let epoch: UUID
    }

    private var usesNativeDelay: Bool {
        Defaults[.autoClearClipboardEnabled] && !UtilityIntegration.shared.owners.contains("clipboardAutoClearDelay")
    }

    private var timerEpoch: UUID?

    /// Arms the delay-based clear. Called by `ClipboardManager` on every copy.
    func noteClipboardChanged() {
        clearTimer?.invalidate()
        clearTimer = nil
        timerEpoch = nil

        guard usesNativeDelay else { return }
        let epoch = delayEpoch.withLock { $0 }
        let delay = max(5, Defaults[.autoClearClipboardSeconds])
        let expectedChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: TimeInterval(delay), repeats: false) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.clearTimer === timer else { return }
                self.clearTimer = nil
                self.timerEpoch = nil
                self.clearPasteboard(expectedChangeCount: expectedChangeCount) {
                    self.usesNativeDelay && self.delayEpoch.withLock { $0 == epoch }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clearTimer = timer
        timerEpoch = epoch
    }

    private func usesNativeTrigger(_ trigger: SystemClearTrigger) -> Bool {
        Defaults[.autoClearClipboardOnLock] && !UtilityIntegration.shared.owners.contains(trigger.rawValue)
    }

    /// Registers or tears down the sleep and lock triggers to match the
    /// setting, so nothing is observed while the feature is off.
    func syncSystemTriggers() {
        let epoch = triggerEpoch.withLock { $0 }
        for trigger in SystemClearTrigger.allCases {
            let wanted = usesNativeTrigger(trigger)
            if let observer = observers[trigger] {
                if wanted && observer.epoch == epoch { continue }
                trigger.center.removeObserver(observer.token)
                observers[trigger] = nil
            }
            guard wanted else { continue }
            let id = UUID()
            let token = trigger.center.addObserver(
                forName: trigger.name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clearPasteboard {
                        self.observers[trigger]?.id == id && self.usesNativeTrigger(trigger)
                            && self.triggerEpoch.withLock { $0 == epoch }
                    }
                }
            }
            observers[trigger] = SystemClearObservation(token: token, id: id, epoch: epoch)
        }
    }

    /// Empties the system pasteboard.
    ///
    /// Saved history is deliberately untouched — the point is that the *system*
    /// pasteboard stops holding a password or token, not that the user loses
    /// what they deliberately kept. The change count is suppressed so clearing
    /// does not itself get filed as a new clipboard entry.
    private func clearPasteboard(expectedChangeCount: Int? = nil, whileAllowed: () -> Bool) {
        guard whileAllowed() else { return }
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        guard ClipboardCapturePolicy.shouldClear(expectedChangeCount: expectedChangeCount,
                                                  currentChangeCount: currentChangeCount),
              currentChangeCount != lastClearedChangeCount,
              whileAllowed() else { return }
        pasteboard.clearContents()
        lastClearedChangeCount = pasteboard.changeCount
        watchedClipboard?.ignoreChangeCount(pasteboard.changeCount)
        clearTimer?.invalidate()
        clearTimer = nil
        timerEpoch = nil
    }

    private var lastClearedChangeCount: Int = -1
}
