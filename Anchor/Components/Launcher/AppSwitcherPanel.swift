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
        acceptsMouseMovedEvents = true
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
    private var invocationModifiers: NSEvent.ModifierFlags = []

    /// The ring's own navigation keys — everything else passes through the
    /// tap untouched, so ordinary typing elsewhere is unaffected by the tap
    /// merely being installed.
    private static let handledKeyCodes: Set<UInt16> = [48, 53, 36, 76, 124, 125, 123, 126, 13]

    private var switcher: AppSwitcherManager { .shared }

    private init() {}

    // MARK: - Invocation

    /// The shortcut fired. Opens the ring, or advances it if already open —
    /// which is what makes holding the modifier and tapping Tab feel like ⌘Tab.
    func invoke(reverse: Bool = false, holding modifiers: NSEvent.ModifierFlags? = nil) {
        guard Defaults[.enableShortcuts], Defaults[.enableAppSwitcher] else { return }
        switcher.startTracking()

        if panel == nil {
            invocationModifiers = modifiers ?? Self.configuredHoldModifiers()
            switcher.show(startingReversed: reverse)
            guard !switcher.apps.isEmpty else { return }
            present()
        } else {
            reverse ? switcher.selectPrevious() : switcher.selectNext()
        }
    }

    private func present(at pointer: CGPoint? = nil, monitors: Bool = true) {
        let mouse = pointer ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.frame ?? .zero
        let diameter = min(switcher.ringDiameter,
                           max(220, min(visibleFrame.width, visibleFrame.height) - 24))
        let origin = originNearPointer(diameter: diameter, mouse: mouse, visibleFrame: visibleFrame)
        // Screen coordinates are y-up; SwiftUI's local coordinates are y-down.
        // Seed the native tracker from the clamped frame, including when the
        // pointer starts outside the circle near a corner.
        let host = AppSwitcherHostingView(diameter: diameter, initialPointerLocation: CGPoint(
            x: mouse.x - origin.x, y: origin.y + diameter - mouse.y), tracksSystemPointer: monitors)

        let panel = AppSwitcherPanel(contentView: host, diameter: diameter)
        panel.ignoresMouseEvents = !monitors
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel

        if monitors { installMonitors() }
    }

    /// Open at the pointer, keeping the entire switcher on the active display.
    /// Near an edge the center shifts only as far as needed to avoid clipping.
    private func originNearPointer(diameter: CGFloat, mouse: NSPoint, visibleFrame: NSRect) -> NSPoint {
        guard !visibleFrame.isEmpty else { return .zero }
        let margin: CGFloat = 8
        let minX = visibleFrame.minX + margin
        let minY = visibleFrame.minY + margin
        let maxX = max(minX, visibleFrame.maxX - diameter - margin)
        let maxY = max(minY, visibleFrame.maxY - diameter - margin)
        return NSPoint(
            x: min(max(mouse.x - diameter / 2, minX), maxX),
            y: min(max(mouse.y - diameter / 2, minY), maxY))
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
        // The tap sees modifier releases for both Anchor and other frontmost
        // apps. Only use the older fallback when permissions prevent a tap.
        if installKeyTap() { return }

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
    private func installKeyTap() -> Bool {
        guard keyTap == nil else { return true }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
            let manager = Unmanaged<AppSwitcherPanelManager>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    manager.dismiss(activating: false)
                    return Unmanaged.passUnretained(cgEvent)
                }
                if type == .flagsChanged {
                    if let event = NSEvent(cgEvent: cgEvent) { manager.handleFlags(event) }
                    return Unmanaged.passUnretained(cgEvent)
                }
                return manager.handleTappedKeyDown(cgEvent)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else { return false }

        keyTap = tap
        keyTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = keyTapRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Swallows the ring's own navigation keys; everything else passes
    /// through unmodified.
    private func handleTappedKeyDown(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        guard panel != nil, let nsEvent = NSEvent(cgEvent: cgEvent) else {
            return Unmanaged.passUnretained(cgEvent)
        }
        if nsEvent.keyCode == 51 {
            switcher.filter(String(switcher.query.dropLast()))
            return nil
        }
        // W now belongs to search; Command-W explicitly closes an app.
        if nsEvent.keyCode == 13 && nsEvent.modifierFlags.contains(.command) {
            handle(nsEvent)
            return nil
        }
        if !Self.handledKeyCodes.contains(nsEvent.keyCode) || nsEvent.keyCode == 13 {
            guard let text = nsEvent.charactersIgnoringModifiers,
                  !text.isEmpty, text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " })
            else { return Unmanaged.passUnretained(cgEvent) }
            switcher.filter(switcher.query + text)
            return nil
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

                let required = self.invocationModifiers
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
    private static func configuredHoldModifiers() -> NSEvent.ModifierFlags {
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

        let required = invocationModifiers
        guard !required.isEmpty else { return }

        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if held.intersection(required).isEmpty {
            dismiss(activating: true)
        }
    }

    #if DEBUG
    /// Exercise native clamped coordinates without moving the real pointer or
    /// posting system input. Real corners may trigger macOS Lock Screen.
    func reviewCornerNavigation(into directory: URL) async {
        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            lines.append("\(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { failures += 1 }
        }
        defer { dismiss(activating: false) }
        switcher.startTracking()
        for (display, screen) in NSScreen.screens.enumerated() {
            let visible = screen.visibleFrame
            let corners = [CGPoint(x: visible.minX + 2, y: visible.minY + 2),
                           CGPoint(x: visible.maxX - 2, y: visible.minY + 2),
                           CGPoint(x: visible.minX + 2, y: visible.maxY - 2),
                           CGPoint(x: visible.maxX - 2, y: visible.maxY - 2)]
            for (corner, point) in corners.enumerated() {
                switcher.show()
                invocationModifiers = []
                present(at: point, monitors: false)
                guard let panel, let host = panel.contentView as? AppSwitcherHostingView else {
                    check("native panel exists", false); continue
                }
                panel.ignoresMouseEvents = true
                check("display \(display), corner \(corner): fully visible", visible.contains(panel.frame))
                let initial = switcher.selectedIndex
                try? await Task.sleep(for: .milliseconds(50))
                check("opening preserves initial selection", switcher.selectedIndex == initial)
                let count = switcher.apps.count
                guard count > 1 else { check("at least two running apps", false); dismiss(activating: false); continue }
                let target = (initial + 1) % count
                let angle = CGFloat(target) * 2 * .pi / CGFloat(count) - .pi / 2
                let local = CGPoint(x: panel.frame.width / 2 + cos(angle) * panel.frame.width * 0.34,
                                    y: panel.frame.height / 2 - sin(angle) * panel.frame.height * 0.34)
                guard let mouseEvent = NSEvent.mouseEvent(with: .mouseMoved, location: local, modifierFlags: [],
                    timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 0, pressure: 0) else { check("native mouse event", false); continue }
                host.mouseEntered(with: mouseEvent)
                check("first entry maps to the visible wedge", switcher.selectedIndex == target)
                for (flags, expected) in [(NSEvent.ModifierFlags(), (target + 1) % count), (.shift, target)] {
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                        timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                        characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) {
                        handle(event)
                        host.updateTrackingAreas()
                        host.mouseMoved(with: mouseEvent)
                        try? await Task.sleep(for: .milliseconds(50))
                        check("\(flags.isEmpty ? "Tab" : "Shift-Tab") survives stationary hover", switcher.selectedIndex == expected)
                    }
                }
                host.mouseExited(with: mouseEvent)
                switcher.select((target + 1) % count)
                host.mouseEntered(with: mouseEvent)
                check("same-point reentry selects", switcher.selectedIndex == target)
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(
                        to: directory.appendingPathComponent("wheel-display\(display)-corner\(corner).png"))
                }
                dismiss(activating: false)
            }
        }
        lines.append("\(failures) failures; no real pointer movement or system input")
        try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("corner-results.txt"), atomically: true, encoding: .utf8)
    }
    #endif
}
