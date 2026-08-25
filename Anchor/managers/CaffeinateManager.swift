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

import Combine
import Defaults
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake, for a set time or until switched off.
///
/// Held as an IOKit power assertion rather than by running `caffeinate`. The
/// assertion lives in the kernel: nothing polls, nothing is scheduled while it
/// is held, and there is no child process to supervise or leak. A timed session
/// costs exactly one timer, which fires once. The upstream implementation this
/// replaces spawned `caffeinate` and watched it with a repeating timer, which
/// both costs CPU and breaks this project's rule against sidecar processes.
@MainActor
final class CaffeinateManager: ObservableObject {
    static let shared = CaffeinateManager()

    @Published private(set) var isActive = false
    /// When a timed session ends. Nil while indefinite or inactive.
    @Published private(set) var endsAt: Date?

    private var assertionID: IOPMAssertionID = 0
    private var expiryTimer: DispatchSourceTimer?

    private init() {}

    /// Start keeping the Mac awake. `duration` of nil runs until stopped.
    ///
    /// Calling this while already active replaces the previous session, so a
    /// second request cannot leak the first assertion.
    func activate(for duration: TimeInterval? = nil) {
        releaseAssertion()

        // Display sleep is the stronger of the two — holding it implies the
        // system stays up — so the preference picks which one is taken rather
        // than taking both.
        let type = Defaults[.caffeinateKeepsDisplayAwake]
            ? kIOPMAssertionTypeNoDisplaySleep
            : kIOPMAssertionTypeNoIdleSleep

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Anchor: keeping this Mac awake" as CFString,
            &id)

        guard result == kIOReturnSuccess else {
            NSLog("CaffeinateManager: could not create power assertion (\(result))")
            return
        }

        assertionID = id
        isActive = true

        guard let duration, duration > 0 else {
            endsAt = nil
            return
        }

        let deadline = Date().addingTimeInterval(duration)
        endsAt = deadline
        scheduleExpiry(after: duration)
    }

    func deactivate() {
        releaseAssertion()
        isActive = false
        endsAt = nil
    }

    func toggle(duration: TimeInterval? = nil) {
        isActive ? deactivate() : activate(for: duration)
    }

    // MARK: - Internals

    /// One-shot. A repeating timer here would keep waking the machine that this
    /// feature exists to keep awake, for no reason after it has fired.
    private func scheduleExpiry(after duration: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + duration, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.deactivate()
        }
        expiryTimer = timer
        timer.resume()
    }

    private func releaseAssertion() {
        expiryTimer?.cancel()
        expiryTimer = nil

        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }
}
