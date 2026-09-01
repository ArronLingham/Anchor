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
import Defaults
import Foundation

/// Decides whether the window under the pointer should be brought forward.
///
/// Pure, so the rules can be tested without moving a real mouse. Every rule
/// here exists to stop the feature firing when the user did not mean it —
/// an unwanted raise steals focus mid-action, which is far more disruptive
/// than a raise that does not happen.
struct FocusFollowsMouseDecision {
    /// How long the pointer must rest before a raise. Below ~150 ms the window
    /// under a pointer merely crossing the screen gets raised.
    var dwellSeconds: Double
    /// Modifiers that suspend the feature while held. Dragging with a modifier
    /// is almost always a deliberate action inside the current window.
    var suspendingModifiers: NSEvent.ModifierFlags

    struct State {
        /// Bundle id (or any stable id) of the app under the pointer.
        var appUnderPointer: String?
        /// The frontmost app right now.
        var frontmostApp: String?
        var isDragging: Bool
        var modifiers: NSEvent.ModifierFlags
        /// How long the pointer has been over `appUnderPointer`.
        var dwellElapsed: Double
        /// True while a menu is open — raising then dismisses the menu.
        var isMenuOpen: Bool
    }

    /// Whether to raise now.
    func shouldRaise(_ state: State) -> Bool {
        // Nothing under the pointer, or nothing identifiable.
        guard let target = state.appUnderPointer, !target.isEmpty else { return false }

        // Already frontmost — raising would be a no-op that still risks
        // reordering that app's own windows.
        if target == state.frontmostApp { return false }

        // A drag is a deliberate action anchored in the source window.
        if state.isDragging { return false }

        // A held modifier means the user is doing something, not browsing.
        if !state.modifiers.intersection(suspendingModifiers).isEmpty { return false }

        // A menu is a modal-ish context; stealing focus closes it.
        if state.isMenuOpen { return false }

        // Finally, the pointer has to have settled.
        return state.dwellElapsed >= dwellSeconds
    }
}

/// Brings the window under the pointer forward after it settles there.
///
/// ## Cost
///
/// One `NSEvent` global monitor for mouse movement while enabled, and nothing
/// at all when off. Movement is *sampled*, not acted on: the manager records
/// where the pointer is and only does the expensive part — an accessibility
/// query and a raise — once the dwell timer fires. So moving the mouse across
/// the screen costs one closure call per event and no AX traffic.
@MainActor
final class FocusFollowsMouseManager {
    static let shared = FocusFollowsMouseManager()

    private var moveMonitor: Any?
    private var dragMonitor: Any?
    private var dwellTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private var lastPoint: NSPoint = .zero
    private var isDragging = false
    private var decision = FocusFollowsMouseDecision(
        dwellSeconds: 0.3, suspendingModifiers: [.command, .option, .control, .shift])

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        Defaults.publisher(.enableFocusFollowsMouse)
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
            .store(in: &cancellables)

        Defaults.publisher(.focusFollowsMouseDelayMs)
            .sink { [weak self] change in
                Task { @MainActor in
                    self?.decision.dwellSeconds = Double(change.newValue) / 1000
                }
            }
            .store(in: &cancellables)

        decision.dwellSeconds = Double(Defaults[.focusFollowsMouseDelayMs]) / 1000
        sync()
    }

    private func sync() {
        Defaults[.enableFocusFollowsMouse] ? install() : remove()
    }

    private func install() {
        guard moveMonitor == nil else { return }

        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
        }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.isDragging = (event.type == .leftMouseDown || event.type == .leftMouseDragged)
            }
        }
    }

    private func remove() {
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        moveMonitor = nil
        dragMonitor = nil
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    /// Restarts the dwell timer. The expensive work happens only when it fires.
    private func pointerMoved(to point: NSPoint) {
        // Ignore sub-pixel jitter, which otherwise resets the dwell forever and
        // means the feature never fires on a slightly unsteady hand.
        if abs(point.x - lastPoint.x) < 2, abs(point.y - lastPoint.y) < 2 { return }
        lastPoint = point

        dwellTimer?.invalidate()
        let timer = Timer(timeInterval: decision.dwellSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dwellElapsed(at: point) }
        }
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    private func dwellElapsed(at point: NSPoint) {
        guard AXIsProcessTrusted() else { return }
        guard let target = appUnderPointer(at: point) else { return }

        let state = FocusFollowsMouseDecision.State(
            appUnderPointer: target.bundleIdentifier ?? String(target.processIdentifier),
            frontmostApp: NSWorkspace.shared.frontmostApplication.map {
                $0.bundleIdentifier ?? String($0.processIdentifier)
            },
            isDragging: isDragging,
            modifiers: NSEvent.modifierFlags,
            // The dwell timer having fired *is* the elapsed dwell.
            dwellElapsed: decision.dwellSeconds,
            isMenuOpen: isMenuOpen())

        guard decision.shouldRaise(state) else { return }
        target.activate(options: [])
    }

    /// The app owning the window under `point`.
    ///
    /// `CGWindowListCopyWindowInfo` is used rather than an accessibility
    /// hit-test because AX has no "window at point" query — every AX route
    /// means walking each app's window list, which is far more traffic on a
    /// path that runs whenever the pointer settles.
    private func appUnderPointer(at point: NSPoint) -> NSRunningApplication? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        // Global (top-left origin) coordinates, to match CGWindowList.
        guard let primary = NSScreen.screens.first else { return nil }
        let flipped = CGPoint(x: point.x, y: primary.frame.maxY - point.y)

        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(flipped),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t
            else { continue }
            // Topmost match wins — CGWindowList is ordered front to back.
            return NSRunningApplication(processIdentifier: pid)
        }
        return nil
    }

    /// True while any app has an open menu.
    private func isMenuOpen() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // Menus live above the normal window layer; 101 is the documented
        // layer for pop-up menus.
        return windows.contains { ($0[kCGWindowLayer as String] as? Int) == 101 }
    }
}
