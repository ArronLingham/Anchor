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
import Foundation

/// Tracks whether background work is worth doing at all.
///
/// Nothing in Atoll used to throttle on display sleep, screen lock, or Low
/// Power Mode — every poller ran at full rate against a screen nobody was
/// looking at. Managers observe `shouldSuspendBackgroundWork` and stop or slow
/// their timers while it is true.
///
/// This deliberately does *not* cover system sleep; managers that care about
/// that already observe `NSWorkspace.willSleepNotification` directly.
///
/// Not `@MainActor`: every mutation below arrives on an observer registered
/// with `queue: .main`, and observers need to subscribe from whatever context
/// their manager happens to run on.
final class SystemActivityGate: ObservableObject, @unchecked Sendable {
    static let shared = SystemActivityGate()

    /// True when no one can see the UI, or the user has asked for less work.
    @Published private(set) var shouldSuspendBackgroundWork = false

    @Published private(set) var isDisplayAsleep = false
    @Published private(set) var isScreenLocked = false
    @Published private(set) var isLowPowerModeEnabled = false

    private init() {
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.update { $0.isDisplayAsleep = true }
        }
        workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.update { $0.isDisplayAsleep = false }
        }

        // Lock state is only published on the distributed centre.
        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.update { $0.isScreenLocked = true }
        }
        distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.update { $0.isScreenLocked = false }
        }

        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.update { $0.isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }

        recomputeSuspension()
    }

    private func update(_ mutate: (SystemActivityGate) -> Void) {
        mutate(self)
        recomputeSuspension()
    }

    private func recomputeSuspension() {
        let suspend = isDisplayAsleep || isScreenLocked || isLowPowerModeEnabled
        if suspend != shouldSuspendBackgroundWork {
            shouldSuspendBackgroundWork = suspend
        }
    }
}
