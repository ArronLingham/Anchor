/*
 * Anchor
 * Copyright (C) 2026 Atoll Contributors
 * SPDX-License-Identifier: GNU GPL-3.0-or-later
 */

import Foundation

/// Defaults notifications may arrive off-main; invalidate before queuing UI
/// reconciliation so an older refresh cannot show a newly disabled widget.
final class WeatherSettingEpoch {
    private let lock = NSLock()
    private var generation = UUID()
    func current() -> UUID { lock.lock(); defer { lock.unlock() }; return generation }
    func invalidate() { lock.lock(); defer { lock.unlock() }; generation = UUID() }
    func accepts(_ ticket: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == ticket }
}

/// The lock screen and each visible launcher widget are independent owners.
/// Fetches remain valid until the last owner leaves or configuration changes.
struct WeatherDemandState {
    private(set) var lockPresentation: UUID?
    private(set) var launchers: Set<UUID> = []
    private(set) var fetchGeneration = UUID()

    var hasDemand: Bool { lockPresentation != nil || !launchers.isEmpty }

    /// A view can disappear a little after its preference changes. A retained
    /// lease must not keep work alive when its control is already off.
    func hasUsableDemand(lockAllowed: Bool, launcherEnabled: Bool) -> Bool {
        (lockPresentation != nil && lockAllowed) || (launcherEnabled && !launchers.isEmpty)
    }

    @discardableResult
    mutating func beginLock() -> UUID {
        let ticket = UUID()
        lockPresentation = ticket
        return ticket
    }

    mutating func endLock() {
        guard lockPresentation != nil else { return }
        lockPresentation = nil
        if !hasDemand { invalidateFetch() }
    }

    mutating func addLauncher(_ id: UUID) { launchers.insert(id) }

    mutating func removeLauncher(_ id: UUID) {
        guard launchers.remove(id) != nil else { return }
        if !hasDemand { invalidateFetch() }
    }

    mutating func invalidateFetch() { fetchGeneration = UUID() }

    func acceptsFetch(_ ticket: UUID) -> Bool { hasDemand && fetchGeneration == ticket }

    func acceptsLock(_ ticket: UUID, enabled: Bool, locked: Bool) -> Bool {
        enabled && locked && lockPresentation == ticket
    }
}
