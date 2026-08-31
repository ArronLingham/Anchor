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
import CoreGraphics
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
/// non-key, and navigation keys are read from a `CGEventTap` rather than
/// an `NSEvent` monitor. That distinction matters: `NSEvent
/// .addGlobalMonitorForEvents`'s own documentation is explicit that a
/// global monitor's handler "will not be able to affect event processing
/// in any way" — it can only observe. Since the panel is never key, the
/// only monitor that ever actually fires while the ring is open is the
/// global one, so Tab/Shift+Tab used to *also* reach whatever app was still
/// focused underneath on every cycle — a held Tab in a text field types a
/// tab character into it once per press. Only a tap can drop the event
/// before it gets there, the same reason `MediaKeyInterceptor` uses one.
@MainActor
final class AppSwitcherPanelManager {
    static let shared = AppSwitcherPanelManager()

    private var panel: AppSwitcherPanel?
    private var keyTap: CFMachPort?
    private var keyTapRunLoopSource: CFRunLoopSource?
    private var flagsMonitor: Any?
    private var releaseWatch: Timer?

    /// The ring's own navigation keys — everything else passes through the
    /// tap untouched, so ordinary typing elsewhere is unaffected by the tap
    /// merely being installed.
    private static let handledKeyCodes: Set<UInt16> = [48, 53, 36, 76, 124, 125, 123, 126, 13]

    private var switcher: AppSwitcherManager { .shared }

    private init() {}

    // MARK: - Invocation

    /// The shortcut fired. Opens the ring, or advances it if already open —
    /// which is what makes holding the modifier and tapping Tab feel like ⌘Tab.
    func invoke(reverse: Bool = false) {
        guard Defaults[.enableAppSwitcher] else { return }

        if panel == nil {
            switcher.show(startingReversed: reverse)
            guard !switcher.apps.isEmpty else { return }
            present()
        } else {
            reverse ? switcher.selectPrevious() : switcher.selectNext()
        }
    }

    private func present() {
        let diameter = switcher.ringDiameter
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

    /// Installs the key tap and the modifier-release watch that drive the
    /// ring while it is up.
    private func installMonitors() {
        installKeyTap()

        // Releasing the shortcut's modifiers commits, the way ⌘Tab does.
        // Modifier-only changes don't type anything into a focused text
        // field, so this stays a plain observing monitor — only the actual
        // navigation keys need the tap's ability to swallow.
        let flags: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlags(event) }
        }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged], handler: flags)

        startReleaseWatch()
    }

    /// Taps `.keyDown` at the HID level so the ring's navigation keys can
    /// actually be dropped rather than merely observed. Needs Accessibility,
    /// same as `MediaKeyInterceptor`'s tap; without it the ring still opens
    /// and the pointer still works, it just cannot be driven from the
    /// keyboard — same fallback behaviour the old monitor-based version had.
    private func installKeyTap() {
        guard keyTap == nil else { return }

        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, _, cgEvent, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
            let manager = Unmanaged<AppSwitcherPanelManager>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { manager.handleTappedKeyDown(cgEvent) }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else { return }

        keyTap = tap
        keyTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = keyTapRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Swallows the ring's own navigation keys; everything else passes
    /// through unmodified.
    private func handleTappedKeyDown(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        guard panel != nil,
              let nsEvent = NSEvent(cgEvent: cgEvent),
              Self.handledKeyCodes.contains(nsEvent.keyCode)
        else {
            return Unmanaged.passUnretained(cgEvent)
        }
        handle(nsEvent)
        return nil
    }

    private func removeKeyTap() {
        if let tap = keyTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = keyTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        keyTap = nil
        keyTapRunLoopSource = nil
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
                guard let self else { return }
                guard self.panel != nil else { return }

                let required = Self.holdModifiers()
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

    /// The modifiers whose release commits the ring.
    ///
    /// Shift is deliberately excluded. It is the *direction* modifier — held
    /// to step backwards and let go to step forwards again, exactly as ⌘⇧Tab
    /// works — so treating it as a hold modifier would commit the ring the
    /// instant the user let go of Shift while still holding Option, halfway
    /// through cycling backwards.
    private static func holdModifiers() -> NSEvent.ModifierFlags {
        let shortcut = KeyboardShortcuts.getShortcut(for: .appSwitcher)
            ?? KeyboardShortcuts.getShortcut(for: .appSwitcherReverse)
        guard let shortcut else { return [] }
        return shortcut.modifiers.intersection([.command, .option, .control])
    }

    private func removeMonitors() {
        removeKeyTap()
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

        let required = Self.holdModifiers()
        guard !required.isEmpty else { return }

        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if held.intersection(required).isEmpty {
            dismiss(activating: true)
        }
    }
}
