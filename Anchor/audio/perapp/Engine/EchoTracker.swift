/*
 * Anchor
 * Per-app audio engine, derived from FineTune (github.com/ronitsingh10/FineTune).
 * Copyright (C) 2026 Ronit Singh
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

import Foundation
import os

/// Reference-counted echo suppression for CoreAudio default-device changes.
///
/// When we programmatically set the system default device, CoreAudio fires a
/// property-changed callback with the same UID. Without suppression, we'd
/// interpret our own change as an external event and re-route apps.
///
/// The tracker is reference-counted (not boolean) so rapid reconnects of the
/// same device increment independently, and each echo is consumed separately.
///
/// Each increment creates a unique token stored in a per-UID set. Timeouts
/// check their own token; consume removes one token. This ensures timeouts
/// are invalidated individually, not en masse.
@MainActor
final class EchoTracker {

    /// Fired when a timeout expires without the echo being consumed.
    /// The caller should re-evaluate the default device.
    var onTimeout: ((_ uid: String) -> Void)?

    private let label: String
    private let logger: os.Logger
    private let timeoutDuration: TimeInterval

    /// Per-UID set of active timeout tokens. Each increment adds one;
    /// each consume or successful timeout removes one.
    private var activeTimeouts: [String: Set<Int>] = [:]
    private var nextToken: Int = 0

    init(label: String, timeoutDuration: TimeInterval = 2.0,
         logger: os.Logger = os.Logger(subsystem: "com.arronlingham.Anchor", category: "EchoTracker")) {
        self.label = label
        self.timeoutDuration = timeoutDuration
        self.logger = logger
    }

    /// Record that we're about to programmatically change the default device.
    /// Must be called *after* confirming the HAL call succeeded.
    func increment(_ uid: String) {
        let token = nextToken
        nextToken += 1
        activeTimeouts[uid, default: []].insert(token)
        let duration = timeoutDuration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            guard self.activeTimeouts[uid]?.remove(token) != nil else { return }
            if self.activeTimeouts[uid]?.isEmpty == true {
                self.activeTimeouts.removeValue(forKey: uid)
            }
            self.logger.warning("\(self.label) echo for \(uid) timed out")
            self.onTimeout?(uid)
        }
    }

    /// Try to consume one pending echo for this UID.
    /// Returns `true` if an echo was pending (caller should ignore the callback).
    func consume(_ uid: String) -> Bool {
        guard let token = activeTimeouts[uid]?.min() else { return false }
        activeTimeouts[uid]?.remove(token)
        if activeTimeouts[uid]?.isEmpty == true {
            activeTimeouts.removeValue(forKey: uid)
        }
        return true
    }

    /// Whether any echo is pending for any device.
    /// Used to skip interim routing when an override is in flight.
    var hasPending: Bool {
        !activeTimeouts.isEmpty
    }
}
