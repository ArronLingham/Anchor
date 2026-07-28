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
    static func insert(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard hasAccessibilityPermission else { throw InjectionError.accessibilityNotTrusted }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)

        do {
            try postPasteKeystroke()
        } catch {
            restore(saved, to: pasteboard)
            throw error
        }

        // The paste is asynchronous from our point of view; give the target app a
        // moment to read the pasteboard before putting the old contents back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            restore(saved, to: pasteboard)
        }
    }

    // MARK: - Keystroke

    private static func postPasteKeystroke() throws {
        guard
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyV, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: virtualKeyV, keyDown: false)
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
