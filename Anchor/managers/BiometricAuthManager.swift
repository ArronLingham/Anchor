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

import Defaults
import Foundation
import LocalAuthentication

/// Touch ID in front of the surfaces that hold other people's secrets.
/// Category 15.
///
/// `LocalAuthentication` needs no entitlement and no privileged helper — the
/// biometric match happens in the Secure Enclave and this process only ever
/// sees a yes or no. Nothing runs until something asks.
@MainActor
final class BiometricAuthManager: ObservableObject {
    static let shared = BiometricAuthManager()

    private init() {}

    /// Whether this Mac can actually do it.
    ///
    /// Checked against a fresh `LAContext` every time: a context caches its
    /// evaluation, so a long-lived one goes stale when a finger is enrolled or
    /// the sensor becomes unavailable.
    var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Human name for whatever this Mac has, for settings copy.
    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .faceID: return "Face ID"
        default: return "biometrics"
        }
    }

    /// When each surface was last unlocked, so a run of interactions does not
    /// prompt every time.
    private var lastUnlock: [String: Date] = [:]

    /// Asks only when the grace period has lapsed.
    ///
    /// Evaluates `deviceOwnerAuthentication`, not the biometrics-only policy,
    /// on purpose: a Mac whose sensor is unavailable — lid shut on an external
    /// display, wet finger, three failed attempts — must still be usable, and
    /// this policy falls back to the login password.
    func authenticate(_ surface: String, reason: String) async -> Bool {
        let grace = TimeInterval(Defaults[.biometricGraceSeconds])
        if let last = lastUnlock[surface], Date().timeIntervalSince(last) < grace {
            return true
        }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Neither biometrics nor a password policy is available. Failing
            // closed would lock the user out of their own clipboard with no way
            // back, so this opens. The setting is a convenience lock over a
            // local UI, not a security boundary, and Settings says so.
            Logger.log(
                "Biometric policy unavailable: \(error?.localizedDescription ?? "unknown")",
                category: .lifecycle)
            return true
        }

        do {
            let granted = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: reason)
            if granted { lastUnlock[surface] = Date() }
            return granted
        } catch {
            // Cancel and failure both land here, and both mean "do not show it".
            return false
        }
    }

    /// Drops every grace period, so walking away re-arms the prompt. Called
    /// when the screen locks.
    func relock() {
        lastUnlock.removeAll()
    }
}
