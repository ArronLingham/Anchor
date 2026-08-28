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
    private var recency: [pid_t] = []
    private var observersInstalled = false

    private init() {}

    // MARK: - Recency

    /// Starts tracking which app was last in front. Cheap: one notification.
    func startTracking() {
        guard !observersInstalled else { return }
        observersInstalled = true

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
            }
        }
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

        let ranked = running.sorted { lhs, rhs in
            let l = recency.firstIndex(of: lhs.processIdentifier) ?? Int.max
            let r = recency.firstIndex(of: rhs.processIdentifier) ?? Int.max
            if l != r { return l < r }
            // Ties are apps never seen activate; alphabetical beats arbitrary.
            return (lhs.localizedName ?? "").localizedCaseInsensitiveCompare(
                rhs.localizedName ?? "") == .orderedAscending
        }

        return ranked.map {
            SwitchableApp(
                pid: $0.processIdentifier,
                name: $0.localizedName ?? "—",
                bundleID: $0.bundleIdentifier,
                icon: $0.icon)
        }
    }

    // MARK: - Presentation

    /// Opens the ring. Starts on the *second* entry — the app you were last in
    /// — which is what makes a single press behave like ⌘Tab.
    func show() {
        apps = snapshot()
        guard !apps.isEmpty else { return }
        selectedIndex = apps.count > 1 ? 1 : 0
        isVisible = true
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
        guard apps.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// Brings the highlighted app forward and closes the ring.
    func activateSelection() {
        defer { hide() }
        guard apps.indices.contains(selectedIndex) else { return }
        let target = apps[selectedIndex]
        guard let app = NSRunningApplication(processIdentifier: target.pid) else { return }
        app.activate(options: [.activateAllWindows])
        noteActivation(target.pid)
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
