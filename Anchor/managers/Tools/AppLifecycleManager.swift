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

// MARK: - Pure decisions

/// Decides whether an app with no windows left should be quit.
///
/// Pure, because every rule here exists to stop the feature quitting something
/// the user still wanted, and those cases — a menu bar app that legitimately
/// has no windows, an app mid-launch, an app the user excluded — are far easier
/// to get right against a table than against a live desktop where a mistake
/// means losing someone's unsaved work.
struct QuitOnCloseDecision {
    /// Apps never quit automatically, whatever their window count.
    ///
    /// Finder has no windows most of the time and quitting it breaks the
    /// desktop. The rest are agents and utilities whose entire purpose is to
    /// run windowless.
    static let alwaysExcluded: Set<String> = [
        "com.apple.finder",
        "com.apple.systemuiserver",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.loginwindow",
        "com.apple.Spotlight",
        "com.arronlingham.Anchor",
    ]

    /// How long after launch to leave an app alone. An app that has started but
    /// not yet drawn its first window looks identical to one whose last window
    /// just closed, and quitting it mid-launch is the worst failure this can
    /// have.
    var launchGraceSeconds: Double = 10
    /// User's own exclusions, by bundle id.
    var userExcluded: Set<String> = []

    struct State {
        var bundleID: String?
        var visibleWindowCount: Int
        /// Seconds since the app launched.
        var sinceLaunch: Double
        /// Whether the app shows a Dock icon. A `LSUIElement` agent has no
        /// windows by design and must never be quit for having none.
        var isRegularApp: Bool
        /// Whether the app has any window at all, including minimised ones.
        /// A minimised window is not a closed window.
        var hasMinimisedWindows: Bool
    }

    func shouldQuit(_ state: State) -> Bool {
        guard let bundleID = state.bundleID, !bundleID.isEmpty else { return false }
        if Self.alwaysExcluded.contains(bundleID) { return false }
        if userExcluded.contains(bundleID) { return false }
        // Agents and accessories are windowless by design.
        guard state.isRegularApp else { return false }
        // Still starting up.
        guard state.sinceLaunch >= launchGraceSeconds else { return false }
        // Minimised is not closed — the user parked it in the Dock deliberately.
        if state.hasMinimisedWindows { return false }
        return state.visibleWindowCount == 0
    }
}

/// Decides whether a media app that just launched should be sent away again.
///
/// macOS launches Music when a Bluetooth headset sends a play command, and some
/// headsets send one on connect. The result is Music opening every time you put
/// your headphones on.
///
/// Pure, and the interesting rule is the last one: an app the *user* opened
/// must never be closed. The distinguishing signal is elapsed time since the
/// user's own launch action, which the manager records.
struct MediaAutoLaunchDecision {
    /// Apps this applies to.
    static let mediaApps: Set<String> = [
        "com.apple.Music",
        "com.apple.iTunes",
        "com.apple.TV",
        "com.apple.podcasts",
    ]

    /// A launch within this long of a user action is treated as deliberate.
    var userIntentWindowSeconds: Double = 5

    struct State {
        var bundleID: String?
        /// Seconds since the user did something that would explain this launch
        /// — clicking the app, using the launcher, opening a media file.
        /// Infinity when there has been no such action.
        var sinceUserIntent: Double
        /// Whether the app was already running. A launch notification for an
        /// app that was already up is an activation, not a launch.
        var wasAlreadyRunning: Bool
    }

    func shouldSuppress(_ state: State) -> Bool {
        guard let bundleID = state.bundleID else { return false }
        guard Self.mediaApps.contains(bundleID) else { return false }
        if state.wasAlreadyRunning { return false }
        // The user asked for this.
        if state.sinceUserIntent < userIntentWindowSeconds { return false }
        return true
    }
}

// MARK: - Manager

/// Quits apps whose last window closes, and stops media apps launching
/// themselves.
///
/// ## Cost
///
/// Both features are notification-driven. Quit-on-close listens for
/// `didTerminateApplicationNotification` and an accessibility observer per
/// running app for window-closed events; there is no polling and no timer.
/// With both switched off nothing is registered at all.
@MainActor
final class AppLifecycleManager {
    static let shared = AppLifecycleManager()

    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private var quitDecision = QuitOnCloseDecision()
    private var mediaDecision = MediaAutoLaunchDecision()

    /// Launch times, so the grace period can be applied. Populated on launch
    /// notifications and seeded for apps already running at startup.
    private var launchTimes: [pid_t: Date] = [:]
    /// When the user last did something that would explain a media app opening.
    private var lastUserIntent = Date.distantPast
    /// AX observers, one per watched app.
    /// Apps with a window-count check already scheduled.
    ///
    /// `kAXUIElementDestroyedNotification` on an *application* element fires
    /// for every destroyed accessibility element in that app — menu items,
    /// buttons, sheets — not just windows. Closing one window can therefore
    /// produce dozens of callbacks, and without this each would schedule its
    /// own deferred AX window-count query. One check per burst is enough,
    /// because the check reads the live window list anyway.
    private var pendingCheck: Set<pid_t> = []
    private var observers: [pid_t: AXObserver] = [:]
    /// Refcon boxes handed to AX, one per observer.
    ///
    /// These cannot be freed while the observer is alive — AX holds the raw
    /// pointer and dereferences it on every callback — so they are kept here
    /// and released in `removeObserver` alongside the observer itself. Without
    /// this they leak one allocation per app, per enable/disable cycle.
    private var refcons: [pid_t: UnsafeMutablePointer<pid_t>] = [:]

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        for app in NSWorkspace.shared.runningApplications {
            launchTimes[app.processIdentifier] = app.launchDate ?? Date.distantPast
        }

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .sink { [weak self] note in
                Task { @MainActor in self?.appLaunched(note) }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .sink { [weak self] note in
                Task { @MainActor in
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                    self?.launchTimes.removeValue(forKey: app.processIdentifier)
                    self?.pendingCheck.remove(app.processIdentifier)
                    self?.removeObserver(for: app.processIdentifier)
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableQuitOnLastWindowClose)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncQuitOnClose() }
            }
            .store(in: &cancellables)

        syncQuitOnClose()
    }

    /// Records that the user did something that could legitimately open a media
    /// app — called from the launcher and the app switcher, so a deliberate
    /// "open Music" is not undone a moment later.
    func noteUserIntent() {
        lastUserIntent = Date()
    }

    // MARK: Media auto-launch

    private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }

        let alreadyKnown = launchTimes[app.processIdentifier] != nil
        launchTimes[app.processIdentifier] = Date()

        if Defaults[.enableQuitOnLastWindowClose] {
            installObserver(for: app)
        }

        guard Defaults[.blockMediaAppAutoLaunch] else { return }

        let state = MediaAutoLaunchDecision.State(
            bundleID: app.bundleIdentifier,
            sinceUserIntent: Date().timeIntervalSince(lastUserIntent),
            wasAlreadyRunning: alreadyKnown)

        guard mediaDecision.shouldSuppress(state) else { return }

        // `terminate` rather than `forceTerminate`: a media app that has just
        // launched has nothing unsaved, but asking politely still lets it run
        // its own teardown, and a refusal leaves the user with an open app
        // rather than a killed one.
        app.terminate()
        NSLog("AppLifecycle: suppressed auto-launch of \(app.bundleIdentifier ?? "?")")
    }

    // MARK: Quit on last window close

    private func syncQuitOnClose() {
        if Defaults[.enableQuitOnLastWindowClose] {
            guard AXIsProcessTrusted() else {
                NSLog("⚠️ AppLifecycle: quit-on-close needs Accessibility")
                return
            }
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular {
                installObserver(for: app)
            }
        } else {
            // Snapshot the keys: removeObserver mutates `observers`, and
            // iterating a dictionary while mutating it is undefined.
            for pid in Array(observers.keys) { removeObserver(for: pid) }
        }
    }

    private func installObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil,
              app.activationPolicy == .regular,
              pid != ProcessInfo.processInfo.processIdentifier,
              let bundleID = app.bundleIdentifier,
              !QuitOnCloseDecision.alwaysExcluded.contains(bundleID)
        else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let pid = refcon.load(as: pid_t.self)
            Task { @MainActor in
                AppLifecycleManager.shared.windowClosed(pid: pid)
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer else { return }

        let box = UnsafeMutablePointer<pid_t>.allocate(capacity: 1)
        box.initialize(to: pid)
        refcons[pid] = box

        let element = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(
            observer, element, kAXUIElementDestroyedNotification as CFString, box)
        AXObserverAddNotification(
            observer, element, kAXWindowMiniaturizedNotification as CFString, box)

        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func removeObserver(for pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        // Free the refcon only after the run loop source is gone, or a callback
        // already in flight would dereference freed memory.
        if let box = refcons.removeValue(forKey: pid) {
            box.deinitialize(count: 1)
            box.deallocate()
        }
    }

    /// A window went away in `pid` — decide whether the app should follow.
    private func windowClosed(pid: pid_t) {
        guard Defaults[.enableQuitOnLastWindowClose],
              let app = NSRunningApplication(processIdentifier: pid)
        else { return }

        // Coalesce: one deferred check per app per burst.
        guard !pendingCheck.contains(pid) else { return }
        pendingCheck.insert(pid)

        // AX reports the destruction before the window list settles, so read
        // it a moment later or the closing window is still counted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingCheck.remove(pid)
                guard !app.isTerminated else { return }

                let counts = self.windowCounts(pid: pid)
                let state = QuitOnCloseDecision.State(
                    bundleID: app.bundleIdentifier,
                    visibleWindowCount: counts.visible,
                    sinceLaunch: Date().timeIntervalSince(
                        self.launchTimes[pid] ?? Date.distantPast),
                    isRegularApp: app.activationPolicy == .regular,
                    hasMinimisedWindows: counts.minimised > 0)

                self.quitDecision.userExcluded = Set(Defaults[.quitOnCloseExcludedApps])
                guard self.quitDecision.shouldQuit(state) else { return }

                app.terminate()
                NSLog("AppLifecycle: quit \(app.bundleIdentifier ?? "?") — last window closed")
            }
        }
    }

    /// Visible and minimised window counts for an app.
    ///
    /// Minimised is counted separately rather than filtered out, because
    /// "minimised" and "no windows" must lead to opposite decisions and a
    /// single total cannot distinguish them.
    private func windowCounts(pid: pid_t) -> (visible: Int, minimised: Int) {
        let element = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return (0, 0) }

        var visible = 0, minimised = 0
        for window in windows {
            var minValue: CFTypeRef?
            let isMinimised = AXUIElementCopyAttributeValue(
                window, kAXMinimizedAttribute as CFString, &minValue) == .success
                && (minValue as? Bool == true)
            isMinimised ? (minimised += 1) : (visible += 1)
        }
        return (visible, minimised)
    }
}
