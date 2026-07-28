/*
 * Atoll (DynamicIsland)
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
import Foundation

/// Delivers transcribed text into whatever app currently has focus.
///
/// Synthesizing ⌘V against the pasteboard is the approach that works across the
/// widest range of apps — the Accessibility value-setting route silently fails in
/// Electron apps, terminals, and anything drawing its own text view. The previous
/// pasteboard contents are restored afterwards so dictation does not clobber the
/// user's clipboard.
///
/// Requires the Accessibility (AXIsProcessTrusted) grant; without it `CGEvent.post`
/// is silently dropped by the window server.
enum TextInjector {
    private static let virtualKeyV: CGKeyCode = 0x09

    enum InjectionError: LocalizedError {
        case accessibilityNotTrusted
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityNotTrusted:
                return String(
                    localized:
                        "Anchor needs Accessibility permission to type dictated text. Grant it in System Settings → Privacy & Security → Accessibility."
                )
            case .eventCreationFailed:
                return String(localized: "Could not synthesize the paste keystroke.")
            }
        }
    }

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Prompts for the Accessibility grant if it has not been made yet.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Pastes `text` into the focused app, restoring the prior pasteboard afterwards.
    ///
    /// Suspends for up to `modifierClearTimeout` waiting for the user's
    /// push-to-talk chord to be released — see `waitForModifiersToClear`.
    static func insert(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard hasAccessibilityPermission else { throw InjectionError.accessibilityNotTrusted }

        // Wait before touching the pasteboard, so a slow release does not leave
        // the transcript sitting on the user's clipboard any longer than needed.
        await waitForModifiersToClear()

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        do {
            try postPasteKeystroke()
        } catch {
            restore(saved, to: pasteboard)
            throw error
        }

        // The paste is asynchronous from our point of view; give the target app a
        // moment to read the pasteboard before putting the old contents back.
        try? await Task.sleep(for: .milliseconds(250))

        // Only restore if nothing else has written to the pasteboard since. If the
        // user copied something in that window, theirs wins — silently reverting it
        // would be data loss.
        guard pasteboard.changeCount == ourChangeCount else { return }
        restore(saved, to: pasteboard)
    }

    // MARK: - Keystroke

    /// Modifiers that would turn ⌘V into a different command if still held.
    private static let pollutingModifiers: CGEventFlags = [.maskShift, .maskAlternate, .maskControl]
    private static let modifierClearTimeout: Duration = .milliseconds(600)
    private static let modifierPollInterval: Duration = .milliseconds(10)

    /// Waits for the user to finish releasing their push-to-talk chord.
    ///
    /// Setting `flags` on a synthesized event does not override the *physical*
    /// modifier state — the window server merges what the keyboard is actually
    /// reporting. With a chord like ⌘⇧D, the D key is usually released a beat
    /// before ⌘ and ⇧, so a paste fired immediately on key-up arrives as ⌘⇧V.
    /// That is "paste as plain text" in Chrome and VS Code, and something else
    /// again elsewhere — the transcript lands wrong, or not at all.
    ///
    /// Returns whether the modifiers actually cleared; the caller pastes either
    /// way, since a mangled paste still beats silently dropping the transcript.
    @discardableResult
    private static func waitForModifiersToClear() async -> Bool {
        var waited: Duration = .zero
        while waited < modifierClearTimeout {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(pollutingModifiers).isEmpty { return true }
            try? await Task.sleep(for: modifierPollInterval)
            waited += modifierPollInterval
        }
        NSLog("TextInjector: modifiers still held after \(modifierClearTimeout); pasting anyway")
        return false
    }

    private static func postPasteKeystroke() throws {
        // A private-state source does not inherit the physical keyboard's
        // modifier flags, so ⌘ is the only modifier these events carry even if
        // the user is somehow still holding the chord.
        guard
            let source = CGEventSource(stateID: .privateState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        else {
            throw InjectionError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        usleep(8_000)
        keyUp.post(tap: .cgSessionEventTap)
    }

    // MARK: - Pasteboard preservation

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var stored: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { stored[type] = data }
            }
            return stored
        }
        return PasteboardSnapshot(items: items)
    }

    private static func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
