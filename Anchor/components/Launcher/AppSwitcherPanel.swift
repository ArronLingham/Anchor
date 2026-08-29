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
import Defaults
import KeyboardShortcuts
import SwiftUI

/// The floating window the app ring is drawn in.
///
/// `.nonactivatingPanel` matters here more than it does for the launcher: the
/// switcher's entire job is to bring *another* app forward, so Anchor must
/// never take activation on the way.
final class AppSwitcherPanel: NSPanel {
    init(contentView: NSView, diameter: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        self.contentView = contentView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // the ring draws its own
        level = .popUpMenu         // above ordinary floating windows
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the ring's window and its key handling.
///
/// ## Why the panel does not take key focus
///
/// Taking key focus would deactivate whatever app the user is in, and on
/// dismissal macOS would hand focus back to *that* app — fighting the
/// activation the switcher is trying to perform. So the panel stays
/// non-key and keys are read from a `CGEvent`-free `NSEvent` global monitor
/// instead, which needs Accessibility but does not disturb focus.
@MainActor
final class AppSwitcherPanelManager {
    static let shared = AppSwitcherPanelManager()

    private var panel: AppSwitcherPanel?
    private var keyMonitors: [Any] = []
    private var flagsMonitor: Any?
    private var releaseWatch: Timer?

    private var switcher: AppSwitcherManager { .shared }

    private init() {}

    // MARK: - Invocation

    /// The shortcut fired. Opens the ring, or advances it if already open —
    /// which is what makes holding the modifier and tapping Tab feel like ⌘Tab.
    func invoke(reverse: Bool = false) {
        guard Defaults[.enableAppSwitcher] else { return }

        if panel == nil {
            switcher.show()
            guard !switcher.apps.isEmpty else { return }
            present()
        } else {
            reverse ? switcher.selectPrevious() : switcher.selectNext()
        }
    }

    private func present() {
        let diameter = Defaults[.appSwitcherRingDiameter]
        let host = NSHostingView(rootView: AppSwitcherView())
        host.frame = NSRect(x: 0, y: 0, width: diameter, height: diameter)

        let panel = AppSwitcherPanel(contentView: host, diameter: diameter)
        positionOnActiveScreen(panel, diameter: diameter)
        panel.orderFrontRegardless()
        self.panel = panel

        installMonitors()
    }

    /// Centred on whichever screen holds the pointer — a ring centred on a
    /// display the user is not looking at would be worse than useless.
    private func positionOnActiveScreen(_ panel: NSPanel, diameter: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - diameter / 2,
            y: frame.midY - diameter / 2))
    }

    func dismiss(activating: Bool) {
        // Both the flags monitor and the release watch can land on the same
        // release; whichever gets here first wins and the other no-ops.
        guard panel != nil else { return }
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        if activating {
            switcher.activateSelection()
        } else {
            switcher.hide()
        }
    }

    // MARK: - Keys

    /// Watches for the keys that drive the ring while it is up.
    ///
    /// Both a local and a global monitor: the local one catches events when
    /// Anchor happens to be frontmost, the global one covers the normal case
    /// where it is not. The global monitor needs Accessibility; without it the
    /// ring still opens and the pointer still works, it just cannot be driven
    /// from the keyboard.
    private func installMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }

        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown], handler: handler) {
            keyMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: {
            handler($0)
            return nil
        }) {
            keyMonitors.append(local)
        }

        // Releasing the shortcut's modifiers commits, the way ⌘Tab does.
        let flags: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlags(event) }
        }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged], handler: flags)

        startReleaseWatch()
    }

    /// Watches for the shortcut's modifiers being let go.
    ///
    /// This exists because the `.flagsChanged` monitor above needs
    /// Accessibility, and without that grant it never fires — so the ring would
    /// open, the user would release ⌥, and nothing whatsoever would happen.
    /// That is exactly what "option-tab doesn't open the app" looks like.
    ///
    /// `NSEvent.modifierFlags` is a static read of the current keyboard state
    /// and needs no grant at all, so polling it is the one reliable route. It
    /// runs only while the ring is on screen — a second or two — and stops the
    /// moment the ring closes.
    private func startReleaseWatch() {
        releaseWatch?.invalidate()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel != nil else { return }
                guard let shortcut = KeyboardShortcuts.getShortcut(for: .appSwitcher) else { return }

                let required = shortcut.modifiers.intersection(
                    [.command, .option, .control, .shift])
                // No modifier to release: the ring waits for Return or Escape.
                guard !required.isEmpty else { return }

                let held = NSEvent.modifierFlags.intersection(
                    [.command, .option, .control, .shift])
                if held.intersection(required).isEmpty {
                    self.dismiss(activating: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseWatch = timer
    }

    private func removeMonitors() {
        for monitor in keyMonitors { NSEvent.removeMonitor(monitor) }
        keyMonitors.removeAll()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        releaseWatch?.invalidate()
        releaseWatch = nil
    }

    private func handle(_ event: NSEvent) {
        guard panel != nil else { return }

        switch event.keyCode {
        case 48:  // Tab
            event.modifierFlags.contains(.shift)
                ? switcher.selectPrevious()
                : switcher.selectNext()
        case 53:  // Escape
            dismiss(activating: false)
        case 36, 76:  // Return, keypad Enter
            dismiss(activating: true)
        case 124, 125:  // Right, Down
            switcher.selectNext()
        case 123, 126:  // Left, Up
            switcher.selectPrevious()
        case 13:  // W — close the highlighted app
            switcher.quitSelection()
            if switcher.apps.isEmpty { dismiss(activating: false) }
        default:
            break
        }
    }

    /// Commits when the shortcut's own modifiers are no longer held.
    ///
    /// Read from the recorded shortcut rather than hardcoded, so rebinding it
    /// to something without a modifier at all still behaves: with no modifiers
    /// to release, this never fires and the ring waits for Return or Escape.
    private func handleFlags(_ event: NSEvent) {
        guard panel != nil else { return }
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .appSwitcher) else { return }

        let required = shortcut.modifiers.intersection(
            [.command, .option, .control, .shift])
        guard !required.isEmpty else { return }

        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if held.intersection(required).isEmpty {
            dismiss(activating: true)
        }
    }
}
