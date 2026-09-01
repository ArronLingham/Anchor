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
import Foundation
import Defaults

/// A launcher result that runs something instead of opening an app.
///
/// Anchor has no Dock icon, so its own settings are otherwise only reachable
/// through the menu bar — being able to type "settings" is the difference
/// between the app being configurable and the settings being a thing you have
/// to go hunting for.
struct LauncherCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbolName: String
    /// Extra terms that should match this command beyond its title.
    let keywords: [String]
    let run: @MainActor () -> Void

    @MainActor
    static let all: [LauncherCommand] = [
        LauncherCommand(
            id: "anchor.settings",
            title: "Anchor Settings",
            subtitle: "Notch, dictation, launcher and more",
            symbolName: "gearshape",
            keywords: ["settings", "preferences", "options", "config", "anchor", "atoll"]
        ) {
            SettingsWindowController.shared.showWindow()
        },
        LauncherCommand(
            id: "anchor.rebuildIndex",
            title: "Rebuild App Index",
            subtitle: "Rescan for newly installed applications",
            symbolName: "arrow.clockwise",
            keywords: ["reindex", "rescan", "refresh", "missing", "index"]
        ) {
            AppIndex.shared.refresh()
        },

        // MARK: - Quick toggles
        //
        // Surfaced as launcher rows rather than a separate palette: the
        // launcher is already a search field the user opens with one shortcut,
        // and these are exactly the "type a few letters, run it" actions it is
        // built for. A second floating palette would duplicate it.
        LauncherCommand(
            id: "toggle.darkMode",
            title: "Toggle Dark Mode",
            subtitle: "Switch between light and dark appearance",
            symbolName: "circle.lefthalf.filled",
            keywords: ["dark", "light", "appearance", "theme", "mode", "night"]
        ) {
            report(QuickToggles.toggleDarkMode())
        },
        LauncherCommand(
            id: "toggle.hiddenFiles",
            title: "Toggle Hidden Files",
            subtitle: "Show or hide dotfiles in Finder",
            symbolName: "eye",
            keywords: ["hidden", "dotfiles", "invisible", "finder", "show"]
        ) {
            report(QuickToggles.toggleHiddenFiles())
        },
        LauncherCommand(
            id: "toggle.desktopIcons",
            title: "Toggle Desktop Icons",
            subtitle: "Show or hide everything on the desktop",
            symbolName: "menubar.dock.rectangle",
            keywords: ["desktop", "icons", "clean", "hide", "tidy"]
        ) {
            report(QuickToggles.toggleDesktopIcons())
        },
        LauncherCommand(
            id: "toggle.emptyTrash",
            title: "Empty Trash",
            subtitle: "Permanently delete everything in the Trash",
            symbolName: "trash",
            keywords: ["trash", "bin", "empty", "delete", "clean"]
        ) {
            report(QuickToggles.emptyTrash())
        },
        LauncherCommand(
            id: "toggle.ejectDisks",
            title: "Eject All Disks",
            subtitle: "Unmount every removable volume",
            symbolName: "eject",
            keywords: ["eject", "unmount", "disk", "drive", "usb", "volume"]
        ) {
            report(QuickToggles.ejectAllDisks())
        },
        // MARK: - Processes
        LauncherCommand(
            id: "system.activityMonitor",
            title: "Activity Monitor",
            subtitle: "Open the Mac's process inspector",
            symbolName: "chart.line.uptrend.xyaxis",
            keywords: ["activity", "monitor", "processes", "cpu", "task manager", "kill"]
        ) {
            let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        },
        LauncherCommand(
            id: "system.forceQuit",
            title: "Force Quit an App",
            subtitle: "Open the Force Quit window",
            symbolName: "xmark.octagon",
            keywords: ["force", "quit", "kill", "unresponsive", "frozen", "hung"]
        ) {
            // ⌥⌘Esc is the system's own Force Quit window. Building a process
            // killer of our own would duplicate it with fewer safeguards.
            let source = CGEventSource(stateID: .combinedSessionState)
            let escape: CGKeyCode = 0x35
            if let down = CGEvent(keyboardEventSource: source, virtualKey: escape, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: escape, keyDown: false) {
                down.flags = [.maskCommand, .maskAlternate]
                up.flags = [.maskCommand, .maskAlternate]
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        },

        // MARK: - Screen capture
        LauncherCommand(
            id: "capture.screenshot",
            title: "Screenshot",
            subtitle: "Capture this display to the clipboard",
            symbolName: "camera.viewfinder",
            keywords: ["screenshot", "capture", "screen", "grab", "png", "shot"]
        ) {
            Task { @MainActor in
                do {
                    let image = try await ScreenCaptureService.captureDisplay()
                    ScreenCaptureService.copyToClipboard(image)
                } catch {
                    report(.failure(error.localizedDescription))
                }
            }
        },
        LauncherCommand(
            id: "capture.screenshotToFile",
            title: "Screenshot to File",
            subtitle: "Capture this display into Pictures",
            symbolName: "photo.badge.arrow.down",
            keywords: ["screenshot", "save", "file", "pictures", "capture"]
        ) {
            Task { @MainActor in
                do {
                    let image = try await ScreenCaptureService.captureDisplay()
                    let url = try ScreenCaptureService.save(image)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    report(.failure(error.localizedDescription))
                }
            }
        },
        LauncherCommand(
            id: "capture.copyText",
            title: "Copy Text From Screen",
            subtitle: "Read this display's text onto the clipboard",
            symbolName: "text.viewfinder",
            keywords: ["ocr", "text", "read", "recognize", "copy", "scan", "extract"]
        ) {
            Task { @MainActor in
                do {
                    let image = try await ScreenCaptureService.captureDisplay()
                    // A QR code is more likely to be what the user wants than
                    // the surrounding page text, so it takes precedence.
                    if let payload = await ScreenCaptureService.detectQRCode(in: image) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(payload, forType: .string)
                        return
                    }
                    let text = try await ScreenCaptureService.recognizeText(in: image)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                } catch {
                    report(.failure(error.localizedDescription))
                }
            }
        },

        LauncherCommand(
            id: "toggle.lockScreen",
            title: "Lock Screen",
            subtitle: "Lock the Mac immediately",
            symbolName: "lock",
            keywords: ["lock", "screen", "secure", "away"]
        ) {
            report(QuickToggles.lockScreen())
        },
    ]

    /// Surfaces the result of a quick toggle.
    ///
    /// These actions are invisible when they work (the appearance changes, the
    /// Trash empties) but equally invisible when they *fail* — an Automation
    /// permission denial in particular. Failures are shown; successes stay
    /// quiet, since the effect is its own confirmation.
    @MainActor
    private static func report(_ outcome: QuickToggles.Outcome) {
        guard case .failure(let message) = outcome else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Commands matching `query`, best first. Matched against the title and
    /// every keyword, keeping whichever scores highest.
    @MainActor
    static func search(_ query: String) -> [ScoredCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // Apple Shortcuts are appended to the static list rather than baked
        // into it: `all` is a `static let` evaluated once, and the user's
        // shortcuts change while the app is running.
        var candidates = all
        if Defaults[.enableShortcutsLauncher] {
            AppleShortcutsManager.shared.loadIfNeeded()
            candidates += AppleShortcutsManager.shared.launcherCommands()
        }

        var results: [ScoredCommand] = []
        for command in candidates {
            var best: FuzzyMatcher.Match?
            for candidate in [command.title] + command.keywords {
                guard let match = FuzzyMatcher.match(query: trimmed, candidate: candidate) else {
                    continue
                }
                if best == nil || match.score > best!.score { best = match }
            }
            guard let best else { continue }
            // Only the title is highlighted, so indices from a keyword match
            // would point at the wrong characters.
            let titleMatch = FuzzyMatcher.match(query: trimmed, candidate: command.title)
            results.append(
                ScoredCommand(
                    command: command,
                    score: best.score,
                    matchedIndices: titleMatch?.matchedIndices ?? []))
        }
        return results.sorted { $0.score > $1.score }
    }

    struct ScoredCommand: Identifiable {
        let command: LauncherCommand
        let score: Int
        let matchedIndices: [Int]
        var id: String { command.id }
    }
}
