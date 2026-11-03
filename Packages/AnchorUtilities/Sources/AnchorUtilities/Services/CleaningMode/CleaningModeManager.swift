// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import SwiftUI

/// "Cleaning mode" temporarily locks the keyboard so the user can wipe it down
/// without typing gibberish, then restores it on a deliberate gesture. The lock
/// is a HID-level event tap that swallows key events before the system handles
/// them, including keyboard system keys such as brightness, media and volume.
/// The very same tap watches for the unlock gesture, so there is always a way
/// back.
///
/// Hold Escape for five continuous seconds to unlock. Tap/session failures
/// still fail open so a broken input filter cannot strand the user.
///
/// Requires Accessibility, like the app's other event taps. If it is missing the
/// tap can't be created, so we never lock the keyboard with no way to unlock it.
final class CleaningModeManager: ObservableObject {
    private static weak var existingInstance: CleaningModeManager?
    static let shared: CleaningModeManager = {
        let value = CleaningModeManager()
        existingInstance = value
        return value
    }()
    static var existing: CleaningModeManager? { existingInstance }

    private static let systemDefinedEventType = CGEventType(rawValue: CleaningSystemKeyEvent.systemDefinedEventTypeRawValue)!
    private static let gestureEventType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue))!
    private static let escapeKeyCode: Int64 = 53
    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        .keyUp,
        .flagsChanged,
        .scrollWheel,
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .otherMouseDown,
        .otherMouseUp,
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
        systemDefinedEventType,
        gestureEventType,
    ].reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << type.rawValue)
    }

    @Published private(set) var isActive = false
    /// Whole seconds of the current Escape hold (0...unlockThreshold).
    @Published private(set) var unlockProgress = 0

    /// Seconds of continuous Escape hold required to unlock.
    let unlockThreshold = 5
    private var escapeHold = CleaningEscapeHold(requiredKeyCode: 53, duration: 5)
    private var escapeTimer: DispatchSourceTimer?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var overlays: [NSPanel] = []
    private var screenObserver: NSObjectProtocol?
    private var shouldRestoreSuspendedFeaturesOnSessionReturn = false
    // Track button down/up while swallowing mouse input so teardown never
    // cuts a physical click in half.
    private var mouseReleaseGate = CleaningMouseReleaseGate()
    /// Ends a user unlock's wait for a release this tap never sees.
    private var releaseDeadline: DispatchWorkItem?

    private init() {
        // A switched-away login session cannot keep a filter tap in the input
        // chain. Cleaning is a temporary local state, so leaving the session
        // ends it; suspended features resume only after this session returns.
        SessionActivity.shared.onChange { [weak self] active in
            guard let self else { return }
            if active {
                guard self.shouldRestoreSuspendedFeaturesOnSessionReturn else { return }
                self.shouldRestoreSuspendedFeaturesOnSessionReturn = false
                self.resumeSuspendedFeatures()
            } else if self.isActive {
                self.deactivate(restoreSuspendedFeatures: false)
            }
        }
    }

    func toggle() { isActive ? deactivate() : activate() }

    /// Starts the lock. No-op (and guides the user) when Accessibility is missing,
    /// because without the tap there would be no way to unlock the keyboard.
    func activate() {
        guard !isActive else { return }
        // Check Accessibility explicitly (same gate the other event taps use) so a
        // missing grant is reported clearly, rather than inferred from a nil tap.
        guard Permissions.shared.accessibility else {
            promptForAccessibility()
            return
        }
        mouseReleaseGate.reset()
        guard installTap() else { return }
        // Debounce must not filter while the lock is up: its tap can run ahead
        // of ours (head-insert order depends on creation order) and would eat
        // the repeated same-key presses the unlock gesture counts on.
        KeyboardDebounceService.shared.suspend()
        MouseClickDebounceService.shared.suspend()
        // Wiping the trackpad is nothing but stray three-finger contacts;
        // middle-click emulation must not fire from them.
        MiddleClickService.shared.suspend()
        MouseNavigationService.shared.suspend()
        // A stray side-button press while wiping the mouse must not type a
        // key combination into the frontmost app (the synthesized keys are
        // posted below this lock's keyboard tap) nor open the wheel over
        // the cleaning overlay.
        MouseButtonShortcutService.shared.suspend()
        RadialMenuService.shared.suspend()
        resetEscapeHold()
        isActive = true
        installScreenObserver()
        showOverlays()
    }

    func deactivate() {
        guard isActive else { return }
        // If a click began while the overlay was up, keep the overlay and tap
        // alive until its real mouse-up passes through. Never manufacture a
        // release: the physical event is the only event that completes the click.
        armReleaseDeadline()
        guard mouseReleaseGate.requestDeactivation() else { return }
        scheduleUserDeactivation()
    }

    /// Every unlock path waits on the gate, and the overlay can cover the menu
    /// bar, so the wait is bounded. Nothing is posted; it only stops waiting.
    private func armReleaseDeadline() {
        guard releaseDeadline == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.releaseDeadline = nil
            guard self.isActive, self.mouseReleaseGate.releaseWaitExpired() else { return }
            self.scheduleUserDeactivation()
        }
        releaseDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CleaningMouseReleaseGate.releaseWaitLimit, execute: work)
    }

    /// Permission teardown must remove the tap before Accessibility is reset.
    func deactivateForSystemTeardown() {
        deactivate(restoreSuspendedFeatures: true)
    }

    private func deactivate(restoreSuspendedFeatures: Bool) {
        guard isActive else { return }
        // Session/tap failure paths cannot wait for another input event. They
        // retain the existing fail-open behaviour and tear down immediately.
        finishDeactivation(restoreSuspendedFeatures: restoreSuspendedFeatures)
    }

    private func scheduleUserDeactivation() {
        // Even when no button is currently held, leave the AppKit control action
        // before unmapping its non-activating panel. A new press may arrive before
        // this block runs, so keep the request pending until teardown completes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.mouseReleaseGate.deactivationPending,
                  self.mouseReleaseGate.pressedButtons.isEmpty else { return }
            self.finishDeactivation(restoreSuspendedFeatures: true)
        }
    }

    private func finishDeactivation(restoreSuspendedFeatures: Bool) {
        guard isActive else { return }
        releaseDeadline?.cancel()
        releaseDeadline = nil
        mouseReleaseGate.reset()
        removeTap()
        removeScreenObserver()
        hideOverlays()
        resetEscapeHold()
        isActive = false
        guard restoreSuspendedFeatures else {
            shouldRestoreSuspendedFeaturesOnSessionReturn = true
            return
        }
        shouldRestoreSuspendedFeaturesOnSessionReturn = false
        resumeSuspendedFeatures()
    }

    private func resumeSuspendedFeatures() {
        // Each owner reads its current availability, preference and permission,
        // so a feature changed while Cleaning Mode was active stays changed.
        KeyboardDebounceService.shared.syncWithPreferences()
        MouseClickDebounceService.shared.syncWithPreferences()
        MiddleClickService.shared.syncWithPreferences()
        MouseNavigationService.shared.syncWithPreferences()
        MouseButtonShortcutService.shared.syncWithPreferences()
        RadialMenuService.shared.syncWithPreferences()
    }

    // MARK: - Event tap

    private func installTap() -> Bool {
        let mask = Self.eventMask
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<CleaningModeManager>.fromOpaque(userInfo).takeUnretainedValue()
                return manager.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        runLoopSource = nil
    }

    /// The tap callback. Its run-loop source lives on the main run loop, so this
    /// runs on the main thread and can touch published state and AppKit directly.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps that stall or when the session locks; re-arm so
        // the keyboard stays locked instead of silently coming back.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if SessionActivity.shared.isActive, AXIsProcessTrusted(), let tap {
                // A disabled tap creates an observation gap: any tracked mouseDown
                // may already have received its real mouseUp while we were blind.
                // Invalidate that incomplete sequence so no later unlock can wait
                // forever for a release that already happened. If the user had
                // already requested deactivation, fail open after the callback.
                let shouldFinishUserDeactivation = mouseReleaseGate.deactivationPending
                mouseReleaseGate.invalidateTrackedPresses()
                resetEscapeHold()
                CGEvent.tapEnable(tap: tap, enable: true)
                if shouldFinishUserDeactivation {
                    scheduleUserDeactivation()
                }
                return nil
            }
            let restoreSuspendedFeatures = SessionActivity.shared.isActive
            DispatchQueue.main.async { [weak self] in
                self?.deactivate(restoreSuspendedFeatures: restoreSuspendedFeatures)
            }
            return Unmanaged.passUnretained(event)
        }

        // Mouse input is swallowed while cleaning, including the overlay.
        if handleMouseButton(type: type, event: event) {
            return nil
        }

        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            registerUnlockKeyDown(code: code, isRepeat: isRepeat)
        } else if type == .keyUp {
            if event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode { resetEscapeHold() }
        } else if type == .flagsChanged {
            // Shift, control, option, command, fn and caps lock arrive here rather
            // than as key-downs, and they are the keys nearest Escape — a cloth
            // resting on them must reset the count like any other key. Both the
            // press and the release report the same key code and neither is
            // Escape, so each one resets and the pair is idempotent. Modifiers
            // never auto-repeat.
            registerUnlockKeyDown(code: event.getIntegerValueField(.keyboardEventKeycode),
                                  isRepeat: false)
        } else if type == Self.systemDefinedEventType,
                  let systemKey = systemKeyEvent(from: event),
                  systemKey.isKeyDown {
            registerUnlockKeyDown(code: systemKey.code, isRepeat: systemKey.isRepeat)
        }

        // Swallow all keyboard, mouse, scroll and trackpad input while locked.
        return nil
    }

    private func handleMouseButton(type: CGEventType, event: CGEvent) -> Bool {
        let button: Int64
        let isDown: Bool
        switch type {
        case .leftMouseDown:
            button = 0
            isDown = true
        case .leftMouseUp:
            button = 0
            isDown = false
        case .rightMouseDown:
            button = 1
            isDown = true
        case .rightMouseUp:
            button = 1
            isDown = false
        case .otherMouseDown:
            button = event.getIntegerValueField(.mouseEventButtonNumber)
            isDown = true
        case .otherMouseUp:
            button = event.getIntegerValueField(.mouseEventButtonNumber)
            isDown = false
        default:
            return false
        }

        if isDown {
            mouseReleaseGate.buttonDown(button)
        } else if mouseReleaseGate.buttonUp(button) {
            // The callback is running on this tap's run loop. Removing the tap
            // here would invalidate it from its own callback stack, so finish on
            // the next main-loop turn after the real release has propagated.
            scheduleUserDeactivation()
        }
        return true
    }

    private func systemKeyEvent(from event: CGEvent) -> CleaningSystemKeyEvent? {
        guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
        return CleaningSystemKeyEvent.decode(subtype: Int(nsEvent.subtype.rawValue),
                                             data1: nsEvent.data1)
    }

    private func registerUnlockKeyDown(code: Int64, isRepeat: Bool) {
        if code != Self.escapeKeyCode { resetEscapeHold(); return }
        escapeHold.keyDown(code: code, time: ProcessInfo.processInfo.systemUptime, isRepeat: isRepeat)
        guard escapeHold.pressedSince != nil, escapeTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.isActive, self.escapeHold.pressedSince != nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = self.escapeHold.elapsed(at: now)
            self.unlockProgress = min(self.unlockThreshold, Int(elapsed))
            if self.escapeHold.isComplete(at: now) {
                self.resetEscapeHold()
                self.deactivate()
            }
        }
        escapeTimer = timer
        timer.resume()
    }

    private func resetEscapeHold() {
        escapeTimer?.cancel()
        escapeTimer = nil
        escapeHold.reset()
        unlockProgress = 0
    }

    // MARK: - Overlay

    private func showOverlays() {
        let frames = NSScreen.screens.map(\.frame)
        let targetFrames = frames.isEmpty
            ? [NSRect(x: 0, y: 0, width: 800, height: 600)]
            : frames
        // Screen notifications can arrive in bursts even when the frames stay
        // unchanged. Reuse those panels so the overlay never flashes or drops a click.
        var reusable = overlays
        overlays = targetFrames.map { frame in
            if let index = reusable.firstIndex(where: { $0.frame == frame }) {
                return reusable.remove(at: index)
            }
            return makeOverlay(frame: frame)
        }
        reusable.forEach { $0.orderOut(nil) }
    }

    private func makeOverlay(frame: NSRect) -> NSPanel {
        let panel = OverlayPanel(contentRect: frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above the menu bar and full-screen apps — the shielding level macOS uses
        // for its own lock-style windows.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // acceptsFirstMouse so the Unlock button fires on the very first click even
        // though the panel never becomes key or activates the app — otherwise that
        // click would just be absorbed as the window-activating click.
        let host = OverlayHostingView(rootView: CleaningOverlayView())
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.orderFrontRegardless()
        return panel
    }

    private func hideOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
    }

    private func installScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.isActive == true else { return }
            self?.showOverlays()
        }
    }

    private func removeScreenObserver() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }

    /// Hosting view that accepts the first click into the (non-key, non-activating)
    /// overlay panel, so the Unlock button works without a throwaway activating click.
    private final class OverlayHostingView: NSHostingView<CleaningOverlayView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private func promptForAccessibility() {
        let strings = L10n.shared.s
        let alert = NSAlert()
        alert.messageText = strings.cleaningNeedsAxTitle
        alert.informativeText = strings.cleaningNeedsAxBody
        alert.addButton(withTitle: strings.permissionOpenSettings)
        alert.addButton(withTitle: strings.uninstallerCancel)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.shared.requestAccessibility()
            Permissions.shared.openAccessibilitySettings()
        }
    }
}
