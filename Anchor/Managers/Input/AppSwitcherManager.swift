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
import ApplicationServices
import Combine
import Defaults
import Foundation

/// One entry in the switcher.
struct SwitchableApp: Identifiable, Equatable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let bundleID: String?
    let icon: NSImage?

    static func == (lhs: SwitchableApp, rhs: SwitchableApp) -> Bool {
        lhs.pid == rhs.pid
    }
}

/// A ring-shaped application switcher.
///
/// ## Ordering
///
/// Most-recently-used, like ⌘Tab, which means the second entry is the app you
/// were just in — the one a switcher is used to get back to. macOS does not
/// hand out that ordering, so it is kept here from
/// `didActivateApplicationNotification`. That notification is the *only*
/// running cost of this feature: no timer, no polling, and no window-server
/// queries until the panel is actually opened.
///
/// ## Why the list is built at open time
///
/// `NSWorkspace.runningApplications` is cheap (an array the workspace already
/// maintains) but the icons are not free to draw, so the snapshot is taken when
/// the ring opens rather than kept live. A switcher that is closed costs
/// nothing at all.
@MainActor
final class AppSwitcherManager: ObservableObject {
    static let shared = AppSwitcherManager()

    @Published private(set) var apps: [SwitchableApp] = []
    @Published var selectedIndex: Int = 0
    @Published private(set) var isVisible = false

    /// PIDs in most-recently-used order, newest first.
    @Published private(set) var query = ""
    private var unfilteredApps: [SwitchableApp] = []
    private var icons: [pid_t: NSImage] = [:]
    private var recency: [pid_t] = []
    private var observersInstalled = false

    /// Whatever was frontmost the moment the ring opened. Reversing back onto
    /// this entry — e.g. Shift+Tab past your own app — is a dismiss, not a
    /// switch: see `activateSelection()`.
    private var originalFrontmostPID: pid_t?

    /// Ring diameter, scaled by how many apps are open. A couple of apps
    /// don't need a disc that dominates the screen; a busy Mac with a dozen
    /// running needs the room. `Defaults[.appSwitcherRingDiameter]` is the
    /// user's configured size at a middling app count, not a fixed size.
    var ringDiameter: CGFloat {
        let base = Defaults[.appSwitcherRingDiameter]
        let count = Double(max(apps.count, 1))
        let lowCount = 3.0, highCount = 16.0
        let t = min(max((count - lowCount) / (highCount - lowCount), 0), 1)
        let scale = 0.8 + t * 0.5   // 0.8x at ≤3 apps, up to 1.3x at 16+
        return CGFloat(base * scale)
    }

    private init() {}

    // MARK: - Recency

    /// Starts tracking which app was last in front. Cheap: one notification.
    func startTracking() {
        guard !observersInstalled else { return }
        observersInstalled = true
        NSWorkspace.shared.runningApplications.forEach { cacheIcon($0) }

        // Seed with whatever is frontmost now, so the very first invocation
        // already has a sensible order rather than an arbitrary one.
        if let front = NSWorkspace.shared.frontmostApplication {
            recency = [front.processIdentifier]
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
                // `activateSelection()` briefly calls `NSApp.activate()` on
                // Anchor itself before handing off to the target app (the
                // two-hop pattern a background accessory app needs to reliably
                // activate a third app) — that also fires this notification
                // for Anchor's own pid. Left unfiltered, Anchor would insert
                // itself at the front of `recency`, so the *next* time the
                // ring opened, `originalFrontmostPID` would be Anchor's pid —
                // which never appears in `apps` (snapshot() excludes non-.regular
                // apps) — so the "don't disturb the app I was already in"
                // guard in `activateSelection()` could never match anything,
                // silently defeating it every time.
                guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.cacheIcon(app)
                self?.noteActivation(app.processIdentifier)
            }
        }
        center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
                self?.recency.removeAll { $0 == app.processIdentifier }
                self?.icons.removeValue(forKey: app.processIdentifier)
            }
        }
    }

    private func cacheIcon(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        // Background helpers can never appear in the ring. Keeping their
        // decoded icons here defeated the shared cache's eviction budget.
        guard app.activationPolicy == .regular, pid != ProcessInfo.processInfo.processIdentifier,
              icons[pid] == nil, let url = app.bundleURL else { return }
        let entry = LauncherApp(url: url, name: app.localizedName ?? "", bundleIdentifier: app.bundleIdentifier)
        if let cached = AppIconCache.shared.icon(for: entry, completion: { [weak self] image in
            guard let self, !app.isTerminated else { return }
            self.icons[pid] = image
            if let index = self.apps.firstIndex(where: { $0.pid == pid }) {
                let old = self.apps[index]
                self.apps[index] = SwitchableApp(pid: pid, name: old.name, bundleID: old.bundleID, icon: image)
            }
        }) { icons[pid] = cached }
    }

    private func noteActivation(_ pid: pid_t) {
        recency.removeAll { $0 == pid }
        recency.insert(pid, at: 0)
        // Bounded so a long uptime cannot grow this without limit.
        if recency.count > 64 { recency.removeLast(recency.count - 64) }
    }

    // MARK: - Snapshot

    /// Builds the ring, most-recently-used first.
    private func snapshot() -> [SwitchableApp] {
        // `.regular` only: agents and UI elements have no windows to switch to,
        // and Anchor itself is one of them, so this also excludes us.
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let ranked = running.sorted { lhs, rhs in
            if lhs.processIdentifier == frontmostPID { return true }
            if rhs.processIdentifier == frontmostPID { return false }
            let l = recency.firstIndex(of: lhs.processIdentifier) ?? Int.max
            let r = recency.firstIndex(of: rhs.processIdentifier) ?? Int.max
            if l != r { return l < r }
            // Ties are apps never seen activate; alphabetical beats arbitrary.
            return (lhs.localizedName ?? "").localizedCaseInsensitiveCompare(
                rhs.localizedName ?? "") == .orderedAscending
        }

        return ranked.map {
            cacheIcon($0)
            return SwitchableApp(
                pid: $0.processIdentifier,
                name: $0.localizedName ?? "—",
                bundleID: $0.bundleIdentifier,
                icon: icons[$0.processIdentifier])
        }
    }

    // MARK: - Presentation

    /// Opens the ring. Starts on the *second* entry — the app you were last in
    /// — which is what makes a single press behave like ⌘Tab. Opening in
    /// reverse instead starts on the *last* entry, mirroring ⌘⇧Tab.
    func show(startingReversed: Bool = false) {
        query = ""
        unfilteredApps = snapshot()
        apps = unfilteredApps
        guard !apps.isEmpty else { return }
        originalFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if apps.count > 1 {
            selectedIndex = startingReversed ? apps.count - 1 : 1
        } else {
            selectedIndex = 0
        }
        isVisible = true
    }

    func filter(_ text: String) {
        query = text
        apps = text.isEmpty ? unfilteredApps : unfilteredApps.filter {
            $0.name.localizedStandardContains(text)
        }
        selectedIndex = 0
    }

    func hide() {
        isVisible = false
    }

    func selectNext() {
        guard !apps.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % apps.count
    }

    func selectPrevious() {
        guard !apps.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + apps.count) % apps.count
    }

    func select(_ index: Int) {
        guard apps.indices.contains(index), selectedIndex != index else { return }
        selectedIndex = index
    }

    /// Brings the highlighted app forward and closes the ring.
    ///
    /// Activate visible apps immediately. Window restoration is only needed
    /// for an app whose every window is minimised, and runs off the main thread
    /// so an unresponsive app cannot freeze the switcher.
    func activateSelection() {
        defer { hide() }
        guard apps.indices.contains(selectedIndex) else { return }
        let target = apps[selectedIndex]

        // Reversing can land back on the app that was already frontmost.
        guard target.pid != originalFrontmostPID else { return }

        guard let app = NSRunningApplication(processIdentifier: target.pid) else { return }

        if app.isHidden { app.unhide() }
        // The common path is an ordinary visible window. Activate it now;
        // querying another process's Accessibility tree before this call can
        // stall the switcher for hundreds of milliseconds (or indefinitely
        // when that process is unresponsive).
        let previousPID = originalFrontmostPID
        if !app.activate(options: [.activateAllWindows]) {
            NSApp.activate()
            app.activate(options: [.activateAllWindows])
        } else {
            // A background accessory app can get an accepted activation that
            // never actually changes focus. Retry the two-hop handoff only if
            // the original app is still frontmost after the handoff settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == previousPID,
                      let retry = NSRunningApplication(processIdentifier: target.pid)
                else { return }
                NSApp.activate()
                retry.activate(options: [.activateAllWindows])
            }
        }
        noteActivation(target.pid)

        // A fully minimised app needs its window restored. Check on a worker
        // queue so a slow AX client never holds up the ring or its next key.
        if AXIsProcessTrusted() {
            let pid = target.pid
            DispatchQueue.global(qos: .userInitiated).async {
                guard Self.restoreMinimisedWindows(pid: pid) else { return }
                DispatchQueue.main.async {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
                }
            }
        }
    }

    /// Restores minimised windows and raises them.
    ///
    /// There is no public API for un-minimising *another* app's window, so this
    /// goes through the accessibility API: clear `AXMinimized`, then perform
    /// `AXRaise` on it. The raise is not optional — clearing `AXMinimized`
    /// alone animates the window out of the Dock but does not bring it in
    /// front of whatever else is on screen, which is indistinguishable from
    /// "nothing happened" if another window is covering it.
    ///
    /// Needs Accessibility; without it this quietly does nothing and the app
    /// still comes forward, just with its windows left in the Dock.
    private nonisolated static func restoreMinimisedWindows(pid: pid_t) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return false }

        // Do not reshuffle an app's windows when it already has one visible.
        // Restore only when every window is minimised.
        guard !windows.isEmpty else { return false }
        for window in windows {
            var minimised: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window, kAXMinimizedAttribute as CFString, &minimised) == .success,
                (minimised as? Bool) == true
            else { return false }
        }
        for window in windows.reversed() {
            AXUIElementSetAttributeValue(
                window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        return true
    }

    /// Closes the highlighted app. Bound to W, matching the convention the ⌘Tab
    /// switcher uses for Q.
    func quitSelection() {
        guard apps.indices.contains(selectedIndex) else { return }
        let target = apps[selectedIndex]
        NSRunningApplication(processIdentifier: target.pid)?.terminate()
        apps.remove(at: selectedIndex)
        if apps.isEmpty {
            hide()
        } else {
            selectedIndex = min(selectedIndex, apps.count - 1)
        }
    }
}
