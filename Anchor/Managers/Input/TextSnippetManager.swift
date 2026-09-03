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
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Defaults
import Foundation

/// Expands typed abbreviations into longer text.
///
/// ## The risk this code carries, and how it is contained
///
/// This watches every keystroke the user types, system-wide. Getting it wrong
/// does not produce a subtle bug — it corrupts what someone is typing, in their
/// email or their editor, with no undo. Four rules follow from that:
///
/// 1. **Never swallow a key.** The tap returns every event unmodified, always.
///    Expansion happens *afterwards*, by synthesising backspaces. So the worst
///    failure is a snippet that does not fire, never a keystroke that vanishes.
/// 2. **Track only what is certain.** The buffer is cleared on any navigation
///    key, modifier chord, click, or app switch — anything after which the
///    cursor may no longer be where the buffer assumes.
/// 3. **Never fire on a password field.** Secure input is checked on every
///    keystroke and disables expansion entirely.
/// 4. **Bounded buffer.** Only as many characters as the longest trigger are
///    kept, so nothing accumulates a transcript of what was typed.
///
/// ## Cost
///
/// One `CGEventTap` while the feature is on, and nothing at all when off. The
/// callback appends one character to a small string and does a suffix compare;
/// no allocation beyond the buffer, no locks.
///
/// ## Privacy
///
/// The buffer lives only in memory, is never logged, never persisted, and is
/// capped at the longest trigger's length.
@MainActor
final class TextSnippetManager: ObservableObject {
    static let shared = TextSnippetManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    /// The tail of what has been typed. Bounded — see `trimBuffer`.
    private var buffer = ""
    /// Set while Anchor is synthesising its own backspaces and text, so the
    /// tap ignores keystrokes it caused itself. Without this, an expansion
    /// containing a trigger would expand again, recursively.
    private var isExpanding = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        Defaults.publisher(.enableTextSnippets)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncTap() }
            }
            .store(in: &cancellables)

        // A snippet list change alters the longest trigger, and therefore how
        // much buffer to keep.
        Defaults.publisher(.textSnippets)
            .sink { [weak self] _ in
                Task { @MainActor in self?.buffer = "" }
            }
            .store(in: &cancellables)

        // Anything that moves the cursor somewhere the buffer does not describe.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.buffer = "" }
        }

        syncTap()
    }

    private func syncTap() {
        Defaults[.enableTextSnippets] ? installTap() : removeTap()
    }

    // MARK: - Tap

    private func installTap() {
        guard eventTap == nil else { return }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<TextSnippetManager>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated { manager.observe(type: type, event: event) }
            // Always pass the event through, unmodified. See the type doc.
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,   // observe after everyone else; we modify nothing
            options: .listenOnly,          // cannot alter or drop events, by construction
            eventsOfInterest: mask,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            NSLog("⚠️ TextSnippetManager: could not create event tap — needs Accessibility and Input Monitoring")
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
        buffer = ""
    }

    // MARK: - Observing

    private func observe(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap, Defaults[.enableTextSnippets] {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        // A click moves the caret somewhere the buffer does not describe.
        if type == .leftMouseDown || type == .rightMouseDown {
            buffer = ""
            lastExpansion = nil
            return
        }

        guard type == .keyDown, !isExpanding else { return }

        // Never expand into a password field.
        guard !IsSecureEventInputEnabled() else {
            buffer = ""
            return
        }

        let flags = event.flags
        // A chord is a command, not typing. Command/Control/Option invalidate
        // the buffer; Shift does not, since it is how capitals are typed.
        if flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskAlternate) {
            buffer = ""
            // Also disarm the undo. ⌘Tab is a chord, and without this a
            // backspace in the app you switched to would revert an expansion
            // that happened in the one you left — typing the trigger into the
            // wrong window.
            lastExpansion = nil
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch keyCode {
        case 51:  // Delete — the buffer no longer matches the field
            // Backspace immediately after an expansion undoes it.
            //
            // The tap is listenOnly by construction, so this keystroke cannot
            // be swallowed — it WILL delete one character of what was inserted.
            // The revert therefore removes the remaining characters and types
            // the trigger back, which lands in the same place a swallow would
            // have, without giving this tap the power to drop keys.
            // A held backspace is not an undo. Auto-repeat keeps deleting in
            // the target app while the revert is inserting, so the two race and
            // over-delete; only a fresh press means "undo that".
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if let pending = lastExpansion, !isRepeat {
                lastExpansion = nil
                revert(pending)
                return
            }
            if isRepeat { lastExpansion = nil }
            if !buffer.isEmpty { buffer.removeLast() }
            return
        case 123, 124, 125, 126,  // arrows
             115, 116, 117, 119, 121,  // home/end/fwd-delete/page up/down
             48, 53:  // tab, escape
            buffer = ""
            lastExpansion = nil
            return
        default:
            break
        }

        // Only the very next keystroke may undo an expansion. "Immediately
        // after" is the whole contract: reverting something typed a paragraph
        // ago would be worse than not offering it.
        lastExpansion = nil

        guard let characters = characters(from: event), !characters.isEmpty else { return }
        buffer.append(contentsOf: characters)
        trimBuffer()

        let snippets = Defaults[.textSnippets]
        guard let match = SnippetMatcher.match(buffer: buffer, snippets: snippets) else { return }
        expand(match)
    }

    /// The characters an event produces, or nil for a key that types nothing.
    private func characters(from event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        let string = String(utf16CodeUnits: chars, count: length)
        // Control characters are not typing.
        guard !string.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control })
        else { return nil }
        return string
    }

    /// Keeps only as much as the longest trigger could need, plus one for a
    /// terminator. Bounds both memory and how much typed text exists at all.
    private func trimBuffer() {
        let longest = Defaults[.textSnippets].map(\.trigger.count).max() ?? 0
        let limit = max(1, longest + 1)
        if buffer.count > limit {
            buffer = String(buffer.suffix(limit))
        }
    }

    // MARK: - Expanding

    private func expand(_ match: SnippetMatcher.Match) {
        buffer = ""
        isExpanding = true

        let clipboard = NSPasteboard.general.string(forType: .string)
        let text = match.snippet.expanded(now: Date(), clipboardText: clipboard)

        Task { @MainActor in
            defer { isExpanding = false }

            // Remove the trigger the user typed, one backspace at a time. The
            // small gap gives the target app time to process each — sending
            // them in a tight loop drops characters in slower apps.
            for _ in 0..<match.charactersToDelete {
                sendBackspace()
                try? await Task.sleep(for: .milliseconds(6))
            }
            try? await Task.sleep(for: .milliseconds(12))

            do {
                try await TextInjector.insert(text)
                // Armed for exactly one keystroke — see the Delete case.
                lastExpansion = Expansion(trigger: match.snippet.trigger, inserted: text)
            } catch {
                NSLog("⚠️ Snippet expansion failed: \(error.localizedDescription)")
            }
        }
    }

    /// What was last expanded, so backspace can put it back.
    private struct Expansion {
        let trigger: String
        let inserted: String
    }

    private var lastExpansion: Expansion?

    /// Undoes an expansion: removes what is left of the inserted text and types
    /// the trigger back.
    ///
    /// One character has already gone — the user's own backspace, which this tap
    /// cannot intercept — so that one is subtracted from the count.
    private func revert(_ expansion: Expansion) {
        guard !expansion.inserted.isEmpty else { return }
        isExpanding = true
        buffer = ""

        Task { @MainActor in
            defer { isExpanding = false }

            let remaining = max(0, expansion.inserted.count - 1)
            for _ in 0..<remaining {
                sendBackspace()
                try? await Task.sleep(for: .milliseconds(6))
            }
            try? await Task.sleep(for: .milliseconds(12))

            do {
                try await TextInjector.insert(expansion.trigger)
            } catch {
                NSLog("⚠️ Snippet revert failed: \(error.localizedDescription)")
            }
        }
    }

    private func sendBackspace() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let backspace: CGKeyCode = 51
        CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: false)?
            .post(tap: .cghidEventTap)
    }
}
