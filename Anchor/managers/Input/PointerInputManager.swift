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

/// Mouse-level input features: wheel direction, and the side buttons.
///
/// ## Why a separate tap from `MediaKeyInterceptor`
///
/// That one watches `NSSystemDefined` and `keyDown` for media and brightness
/// keys. This watches scroll and "other" mouse buttons. Keeping them apart
/// means a failure or a disable in one cannot take the other down, and each
/// tap's event mask stays as narrow as possible — a tap that asks for more
/// events than it needs is called more often, on the input path, for nothing.
///
/// ## Cost
///
/// Zero when both features are off: no tap is created at all. When on, one
/// `CGEventTap` sees the events in its mask and returns them unmodified unless
/// a rule applies. The callback does no allocation and takes no locks.
///
/// ## Trackpads are deliberately left alone
///
/// Scroll inversion applies only to a real wheel. macOS's "natural scrolling"
/// already governs the trackpad, and inverting both would fight it — the user
/// would flip one setting and have the other silently cancel it out. A wheel
/// event carries `scrollWheelEventIsContinuous == 0`; a trackpad's is 1, and
/// those pass through untouched.
@MainActor
final class PointerInputManager {
    static let shared = PointerInputManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        for publisher in [
            Defaults.publisher(.invertScrollVertical).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.invertScrollHorizontal).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.mouseSideButtonNavigation).map { _ in () }.eraseToAnyPublisher(),
        ] {
            publisher
                .sink { [weak self] in
                    Task { @MainActor in self?.syncTap() }
                }
                .store(in: &cancellables)
        }

        syncTap()
    }

    private var isAnyFeatureEnabled: Bool {
        Defaults[.invertScrollVertical]
            || Defaults[.invertScrollHorizontal]
            || Defaults[.mouseSideButtonNavigation]
    }

    private func syncTap() {
        isAnyFeatureEnabled ? installTap() : removeTap()
    }

    // MARK: - Tap

    private func installTap() {
        guard eventTap == nil else { return }

        let mask = (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<PointerInputManager>.fromOpaque(userInfo).takeUnretainedValue()
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
            NSLog("⚠️ PointerInputManager: could not create event tap — Accessibility and Input Monitoring are both required")
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
    }

    // MARK: - Handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long or that the user interrupts.
        // Re-enabling is the difference between the feature working once and
        // working all session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap, isAnyFeatureEnabled {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .scrollWheel:
            return handleScroll(event)
        case .otherMouseDown, .otherMouseUp:
            return handleOtherMouseButton(type: type, event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // Continuous means trackpad/Magic Mouse momentum — governed by the
        // system's own natural-scrolling setting, so not ours to touch.
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else {
            return Unmanaged.passUnretained(event)
        }

        if Defaults[.invertScrollVertical] {
            // Both the line-based and the pixel-based field have to be flipped:
            // apps read whichever they prefer, and flipping only one leaves
            // some apps scrolling the old way and others the new way.
            let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let points = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -lines)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -points)
        }

        if Defaults[.invertScrollHorizontal] {
            let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            let points = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -lines)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -points)
        }

        return Unmanaged.passUnretained(event)
    }

    /// Maps mouse buttons 3 and 4 to ⌘[ and ⌘] — Back and Forward.
    ///
    /// macOS has no system-wide notion of "back": each app binds its own, but
    /// ⌘[ / ⌘] is near-universal in Finder and every browser. Synthesising the
    /// keystroke therefore reaches far more apps than trying to post a
    /// navigation event would.
    private func handleOtherMouseButton(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard Defaults[.mouseSideButtonNavigation] else {
            return Unmanaged.passUnretained(event)
        }

        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        // 3 is "back" and 4 is "forward" on every two-button-plus mouse macOS
        // reports. Anything higher is a mouse-specific extra and is left alone.
        guard button == 3 || button == 4 else {
            return Unmanaged.passUnretained(event)
        }

        // Act on the press and swallow the matching release, so the app never
        // sees a half-click of a button it might have its own meaning for.
        guard type == .otherMouseDown else { return nil }

        let bracket: CGKeyCode = button == 3 ? 0x21 : 0x1E  // kVK_ANSI_LeftBracket / RightBracket
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: bracket, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: bracket, keyDown: false)
        else { return nil }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return nil
    }
}
