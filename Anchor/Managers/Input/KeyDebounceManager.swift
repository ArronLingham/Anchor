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
import CoreGraphics
import Defaults
import Foundation

/// Decides whether a keystroke is a real press or a worn switch bouncing.
///
/// Pure and separated from the event tap so the timing rules can be tested
/// without a failing keyboard to hand.
///
/// ## The rule, and why it is this rule
///
/// A chattering switch produces a *second* press of the **same** key within a
/// few milliseconds of the first. So a repeat is suppressed only when both the
/// key and the interval match. Two different keys in quick succession is
/// ordinary fast typing and must never be touched; the same key pressed twice
/// deliberately ("hello") is far slower than any bounce, which is why the
/// threshold defaults low.
struct KeyDebounceFilter {
    /// Presses of the same key closer together than this are treated as bounce.
    ///
    /// Default 25 ms: measured chatter is typically under 20 ms, while a
    /// deliberate double-tap of one key is rarely under 80 ms even when typing
    /// fast. Anything above ~50 ms starts eating real keystrokes, which is a
    /// far worse failure than letting a bounce through.
    var thresholdSeconds: Double

    /// Last accepted press time per key code.
    private var lastAccepted: [Int64: Double] = [:]

    init(thresholdSeconds: Double = 0.025) {
        self.thresholdSeconds = thresholdSeconds
    }

    /// Whether this press should reach the app.
    ///
    /// `timestamp` is seconds on a monotonic clock. Mutating, because the
    /// decision depends on what came before.
    mutating func shouldAccept(keyCode: Int64, timestamp: Double) -> Bool {
        defer { lastAccepted[keyCode] = timestamp }

        guard let previous = lastAccepted[keyCode] else { return true }

        let elapsed = timestamp - previous
        // A non-positive interval means the clock moved backwards or two events
        // share a timestamp. Accepting is the safe reading: dropping a
        // keystroke the user really typed is the failure that matters.
        guard elapsed > 0 else { return true }

        // Compare with a small tolerance. `2.125 - 2.1` is 0.0249999… in
        // binary floating point, so an interval exactly at the threshold would
        // otherwise be suppressed — and suppressing a real keystroke is the
        // failure this whole type is built to avoid. Borderline resolves to
        // accept, consistently with the rule above.
        let epsilon = 1e-9
        return elapsed >= thresholdSeconds - epsilon
    }

    /// Forgets history — used when the feature is switched off and on, so a
    /// stale timestamp cannot suppress the first real press.
    mutating func reset() {
        lastAccepted.removeAll()
    }
}

/// Filters the doubled letters a worn keyboard invents.
///
/// ## This one *does* swallow events, unlike the snippet tap
///
/// Suppressing a bounce means the duplicate must not reach the app, so this
/// needs `.defaultTap` rather than `.listenOnly`. That makes it the riskiest
/// tap in the app: a bug here silently eats real keystrokes. Three things
/// contain that:
///
/// 1. The threshold is small (25 ms default, capped at 100 ms in settings).
///    Above that it would start eating deliberate double-taps.
/// 2. Only `keyDown` is tapped. Key-up, modifiers and every other event pass
///    through untouched.
/// 3. Ambiguity always resolves to *accept*. A missing or non-monotonic
///    timestamp lets the key through rather than dropping it.
///
/// ## Cost
///
/// One tap while enabled, nothing when off. The callback does a dictionary
/// lookup and a subtraction.
@MainActor
final class KeyDebounceManager {
    static let shared = KeyDebounceManager()

    private var filter = KeyDebounceFilter()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    /// How many presses have been suppressed, so Settings can show whether the
    /// feature is doing anything — a debouncer that never fires is a hint the
    /// keyboard is fine and the feature can be turned off.
    @Published private(set) var suppressedCount = 0

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        Defaults.publisher(.enableKeyDebounce)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncTap() }
            }
            .store(in: &cancellables)

        Defaults.publisher(.keyDebounceMilliseconds)
            .sink { [weak self] change in
                Task { @MainActor in
                    self?.filter.thresholdSeconds = Double(change.newValue) / 1000
                }
            }
            .store(in: &cancellables)

        filter.thresholdSeconds = Double(Defaults[.keyDebounceMilliseconds]) / 1000
        syncTap()
    }

    private func syncTap() {
        Defaults[.enableKeyDebounce] ? installTap() : removeTap()
    }

    private func installTap() {
        guard eventTap == nil else { return }
        filter.reset()

        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<KeyDebounceManager>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { manager.handle(type: type, event: event) }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            NSLog("⚠️ KeyDebounceManager: could not create event tap — needs Accessibility and Input Monitoring")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        filter.reset()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap, Defaults[.enableKeyDebounce] {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        // An auto-repeat is the OS repeating a held key, not a bounce, and must
        // pass through or holding a key stops working.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // CGEvent timestamps are mach absolute time in nanoseconds.
        let timestamp = Double(event.timestamp) / 1_000_000_000

        if filter.shouldAccept(keyCode: keyCode, timestamp: timestamp) {
            return Unmanaged.passUnretained(event)
        }
        suppressedCount += 1
        return nil
    }
}
