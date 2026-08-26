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

import SwiftUI

/// Hides its content until the user authenticates.
///
/// The content closure is only *called* once unlocked, so a gated view is never
/// built and never renders anything behind the lock. Gating with `.opacity` or
/// `.blur` would leave the real text one screenshot away.
struct BiometricGate<Content: View>: View {
    /// Identifies the surface for the unlock grace period, so unlocking notes
    /// does not silently unlock the clipboard.
    let surface: String
    let reason: String

    /// When false the gate is transparent — the caller's feature flag.
    let enabled: Bool

    @ViewBuilder let content: () -> Content

    @State private var unlocked = false
    @State private var checking = false

    var body: some View {
        Group {
            if !enabled || unlocked {
                content()
            } else {
                lockedPlaceholder
            }
        }
        .onChange(of: enabled) { _, isOn in
            // Turning the lock on mid-session must take effect immediately,
            // not at the next launch.
            if isOn { unlocked = false }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWorkspace.screensDidSleepNotification)
        ) { _ in
            unlocked = false
        }
    }

    private var lockedPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)

            Button(checking ? "Waiting…" : "Unlock") { unlock() }
                .buttonStyle(.borderless)
                .disabled(checking)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { unlock() }
        .onAppear { unlock() }
    }

    private func unlock() {
        guard !checking, !unlocked else { return }
        checking = true
        Task { @MainActor in
            let granted = await BiometricAuthManager.shared.authenticate(
                surface, reason: reason)
            checking = false
            unlocked = granted
        }
    }
}
