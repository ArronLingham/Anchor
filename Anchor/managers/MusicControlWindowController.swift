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
import Foundation

/// Decides when the floating music-control window is on screen, and keeps it in
/// step with the notch.
///
/// This was eight `@State` properties and twenty methods on `ContentView`. None
/// of it draws anything: it is a state machine over three `Task`s, a visibility
/// deadline, a suppression flag and a deferred-sync queue, driving an AppKit
/// window through `MusicControlWindowManager`. `@State` is storage for a value a
/// view renders, not for cancellable work with a lifetime of its own, and
/// holding tasks there meant every escaping closure had to reach back into a
/// struct that SwiftUI is free to recreate.
///
/// **One instance per `ContentView`, matching the `@State` it replaces.** That
/// is deliberately not a singleton: with `showOnAllDisplays` there is a window,
/// a view model and a `ContentView` per screen, so making this shared would
/// silently collapse N state machines into one and change behaviour under cover
/// of a refactor.
///
/// `MusicControlWindowManager` is now per-display too. It used to be a single
/// shared instance that all N controllers drove, so presenting dragged the one
/// panel onto whichever notch synced last, and a hide from one screen tore down
/// a window another screen still wanted — leaving that screen believing its
/// window was up and refusing to re-present. Each controller now talks to the
/// manager for the display it presented on, tracked in `boundScreen` rather
/// than resolved from the weak view model, so a hide always lands on the panel
/// it opened.
@MainActor
final class MusicControlWindowController {

    /// Values the view owns that the window's geometry depends on.
    ///
    /// Pushed in on change rather than pulled at sync time. Pulling would mean
    /// holding a closure over the `ContentView` struct, and since this object
    /// lives in that view's `@State`, the closure would capture the same storage
    /// that owns it. All three change rarely — hover in/out, gesture start/end,
    /// a corner-radius preference — so pushing is also less work than the
    /// closure would have been.
    struct Chrome: Equatable {
        var isHovering = false
        var gestureProgress: CGFloat = 0
        var closedBottomCornerRadius: CGFloat = 0
    }

    /// How long the window stays up after playback pauses.
    private let pauseGrace: TimeInterval = 5
    /// Grace before updates resume once the notch closes, so the window is not
    /// measured against a notch that is still animating.
    private let resumeDelay: TimeInterval = 0.24

    private weak var viewModel: AnchorViewModel?

    /// The display this controller presented on, remembered so `hide()` tears
    /// down the panel it actually opened. `viewModel` is weak and the screen
    /// can change under us; resolving it lazily would let a hide land on
    /// another display's window, which is the bug this per-screen split exists
    /// to fix.
    private var boundScreen: String?
    private var chrome = Chrome()

    private var isWindowVisible = false
    private var visibilityDeadline: Date?
    private var isSuppressed = false
    private var hasPendingSync = false
    private var pendingForceRefresh = false

    private var pendingSyncTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var suppressionTask: Task<Void, Never>?

    // MARK: - Wiring

    /// `vm` is an `@EnvironmentObject`, so it does not exist when `@State` is
    /// initialised. The view hands it over from `onAppear`.
    func configure(viewModel: AnchorViewModel) {
        self.viewModel = viewModel
    }

    func updateChrome(_ chrome: Chrome) {
        guard chrome != self.chrome else { return }
        self.chrome = chrome
    }

    func teardown() {
        cancelSync()
        cancelVisibilityTimer()
        suppressionTask?.cancel()
        suppressionTask = nil
        hide()
        clearVisibilityDeadline()
    }

    // MARK: - Inputs from the view

    func handlePlaybackChange(isPlaying: Bool) {
        guard isEnabled else { return }

        if isPlaying {
            clearVisibilityDeadline()
            requestSyncIfHidden()
        } else {
            extendVisibilityAfterPause()
        }
    }

    func handleIdleChange(isIdle: Bool) {
        guard isEnabled else { return }

        if isIdle {
            if visibilityDeadline == nil {
                extendVisibilityAfterPause()
            }
        } else if MusicManager.shared.isPlaying {
            clearVisibilityDeadline()
        }
    }

    func handleStandardControlsAvailabilityChange() {
        guard isEnabled else {
            hide()
            return
        }

        if standardControlsActive {
            if MusicManager.shared.isPlaying || !MusicManager.shared.isPlayerIdle {
                clearVisibilityDeadline()
            }
            enqueueSync(forceRefresh: true)
        } else {
            cancelSync()
            hide()
            clearVisibilityDeadline()
            hasPendingSync = false
            pendingForceRefresh = false
        }
    }

    /// The window's own feature flag, or the music live activity, was turned
    /// off. Drop everything, including anything queued.
    func disable() {
        cancelSync()
        hide()
        clearVisibilityDeadline()
        hasPendingSync = false
        pendingForceRefresh = false
    }

    /// Something took the screen away — the notch opened, or the Mac locked.
    /// Stop updating and take the window down, but keep the deadline so playback
    /// state survives the interruption.
    func suspend() {
        suppressUpdates()
        cancelSync()
        hide()
    }

    /// The interruption ended. Defaults to `resumeDelay`; pass 0 where there is
    /// nothing to wait for, such as a post-unlock deferral clearing.
    func resume(after delay: TimeInterval? = nil) {
        releaseUpdates(after: delay ?? resumeDelay)
        enqueueSync(forceRefresh: true, delay: 0.05)
    }

    /// Adopt whatever the current notch and lock state imply. Called on appear,
    /// where the view may be rebuilt into a world that moved while it was gone.
    func adoptCurrentState() {
        isSuppressed = !canPresent
    }

    func requestSyncIfHidden(forceRefresh: Bool = false, delay: TimeInterval = 0) {
        guard !isWindowVisible else { return }
        enqueueSync(forceRefresh: forceRefresh, delay: delay)
    }

    func clearVisibilityDeadline() {
        visibilityDeadline = nil
        cancelVisibilityTimer()
    }

    /// Clears the deadline only if it has already passed. The view calls this on
    /// appear, where a deadline left over from before the view was rebuilt would
    /// otherwise keep the window up past its grace period.
    func clearVisibilityDeadlineIfExpired() {
        guard let deadline = visibilityDeadline, Date() > deadline else { return }
        clearVisibilityDeadline()
    }

    func suppressUpdates() {
        isSuppressed = true
        suppressionTask?.cancel()
        suppressionTask = nil
    }

    func releaseUpdates(after delay: TimeInterval) {
        suppressionTask?.cancel()
        suppressionTask = Task { [weak self, delay] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }

            if self.canPresent {
                self.isSuppressed = false
                self.flushPendingSyncIfNeeded()
            } else {
                self.isSuppressed = true
            }
            self.suppressionTask = nil
        }
    }

    // MARK: - Scheduling

    func enqueueSync(forceRefresh: Bool, delay: TimeInterval = 0) {
        if shouldDeferSync {
            hasPendingSync = true
            if forceRefresh { pendingForceRefresh = true }
            log("Queued floating window sync (force: \(forceRefresh)) while deferred")
            return
        }

        log("Scheduling floating window sync (force: \(forceRefresh), delay: \(delay))")
        scheduleSync(forceRefresh: forceRefresh, delay: delay)
    }

    /// Re-measure and re-present, but only if the window is actually up. The
    /// view calls this when the notch geometry it depends on moves — hover,
    /// gesture progress, a notch resize — and there is no point scheduling work
    /// for a window that is not showing.
    func resyncGeometryIfShowing(delay: TimeInterval = 0) {
        guard shouldShowWindow else { return }
        enqueueSync(forceRefresh: true, delay: delay)
    }

    func cancelSync() {
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
    }

    func hide() {
        guard isWindowVisible else { return }
        MusicControlWindowManager.manager(for: boundScreen).hide()
        isWindowVisible = false
        boundScreen = nil
    }

    // MARK: - Internals

    private var isEnabled: Bool { Defaults[.musicControlWindowEnabled] }

    private var standardControlsActive: Bool {
        Defaults[.showStandardMediaControls] && !Defaults[.enableMinimalisticUI]
    }

    private var isHUDDeferredAfterUnlock: Bool {
        LockScreenManager.shared.shouldDelayPostUnlockMusicHUD
    }

    /// The notch is closed, the screen is unlocked, and no post-unlock deferral
    /// is in effect.
    private var canPresent: Bool {
        guard let viewModel else { return false }
        return viewModel.notchState == .closed
            && !LockScreenManager.shared.isLocked
            && !isHUDDeferredAfterUnlock
    }

    private var shouldDeferSync: Bool { !canPresent || isSuppressed }

    private var visibilityIsActive: Bool {
        if MusicManager.shared.isPlaying { return true }
        guard let deadline = visibilityDeadline else { return false }
        return Date() <= deadline
    }

    private var shouldShowWindow: Bool {
        guard let viewModel,
              isEnabled,
              AnchorViewCoordinator.shared.musicLiveActivityEnabled,
              standardControlsActive,
              !viewModel.hideOnClosed,
              canPresent,
              !isSuppressed
        else { return false }

        return visibilityIsActive
    }

    private func extendVisibilityAfterPause() {
        let deadline = Date().addingTimeInterval(pauseGrace)
        visibilityDeadline = deadline
        scheduleVisibilityCheck(deadline: deadline)
        requestSyncIfHidden()
    }

    private func scheduleVisibilityCheck(deadline: Date) {
        cancelVisibilityTimer()

        let interval = max(0, deadline.timeIntervalSinceNow)

        hideTask = Task { [weak self, interval] in
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }

            if let current = self.visibilityDeadline, current <= Date() {
                self.visibilityDeadline = nil
            }
            self.enqueueSync(forceRefresh: false)
            self.hideTask = nil
        }
    }

    private func cancelVisibilityTimer() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func flushPendingSyncIfNeeded() {
        guard hasPendingSync else { return }

        let shouldForce = pendingForceRefresh
        hasPendingSync = false
        pendingForceRefresh = false

        log("Flushing pending floating window sync (force: \(shouldForce))")
        scheduleSync(forceRefresh: shouldForce, bypassSuppression: true)
    }

    private func scheduleSync(
        forceRefresh: Bool, delay: TimeInterval = 0, bypassSuppression: Bool = false
    ) {
        cancelSync()

        guard shouldShowWindow else {
            hasPendingSync = false
            pendingForceRefresh = false
            hide()
            return
        }

        if !bypassSuppression && (isSuppressed || !canPresent) {
            hasPendingSync = true
            if forceRefresh { pendingForceRefresh = true }
            return
        }

        hasPendingSync = false
        pendingForceRefresh = false

        let syncDelay = max(0, delay)

        pendingSyncTask = Task { [weak self, forceRefresh, syncDelay] in
            if syncDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(syncDelay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }

            if self.shouldShowWindow {
                self.log("Running floating window sync (force: \(forceRefresh))")
                self.sync(forceRefresh: forceRefresh)
            } else {
                self.log("Skipping floating window sync (conditions changed)")
                self.hide()
            }
            self.pendingSyncTask = nil
        }
    }

    private func currentMetrics() -> MusicControlWindowMetrics? {
        guard let viewModel else { return nil }
        return MusicControlWindowMetrics(
            notchHeight: max(viewModel.closedNotchSize.height, viewModel.effectiveClosedNotchHeight),
            notchWidth: viewModel.closedNotchSize.width + (chrome.isHovering ? 8 : 0),
            rightWingWidth: max(
                0,
                viewModel.effectiveClosedNotchHeight - (chrome.isHovering ? 0 : 12)
                    + chrome.gestureProgress / 2),
            cornerRadius: chrome.closedBottomCornerRadius,
            spacing: 36
        )
    }

    private func sync(forceRefresh: Bool) {
        guard let viewModel else { return }

        let notchAvailable =
            viewModel.effectiveClosedNotchHeight > 0 && viewModel.closedNotchSize.width > 0
        let targetVisible = shouldShowWindow && notchAvailable

        guard targetVisible, let metrics = currentMetrics() else {
            hide()
            return
        }

        if !isWindowVisible {
            let screen = viewModel.screen
            isWindowVisible = MusicControlWindowManager.manager(for: screen).present(
                using: viewModel, metrics: metrics)
            boundScreen = isWindowVisible ? screen : nil
        } else if forceRefresh {
            // The notch can move between displays while the panel is up. Follow
            // it by tearing the old panel down rather than refreshing a window
            // that now belongs to a different screen.
            if boundScreen != viewModel.screen {
                MusicControlWindowManager.manager(for: boundScreen).hide()
                let screen = viewModel.screen
                isWindowVisible = MusicControlWindowManager.manager(for: screen).present(
                    using: viewModel, metrics: metrics)
                boundScreen = isWindowVisible ? screen : nil
            } else if !MusicControlWindowManager.manager(for: boundScreen)
                .refresh(using: viewModel, metrics: metrics)
            {
                MusicControlWindowManager.manager(for: boundScreen).hide()
                isWindowVisible = false
                boundScreen = nil
            }
        }
    }

    private static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private func log(_ message: String) {
        #if DEBUG
        print("[MusicControl] \(Self.logFormatter.string(from: Date())): \(message)")
        #endif
    }
}
