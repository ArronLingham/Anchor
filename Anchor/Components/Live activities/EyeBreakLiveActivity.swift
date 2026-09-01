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

/// The closed-notch break prompt.
///
/// The countdown is driven by TimelineView off a fixed end date rather than by
/// a published per-second value. Nothing ticks while this is off screen, and the
/// manager never has to push a value a view might not be watching — the same
/// reason MusicManager's elapsed time is read rather than observed.
struct EyeBreakLiveActivity: View {
    @ObservedObject private var manager = EyeBreakManager.shared

    var body: some View {
        if case .resting(let until) = manager.phase {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)

                Text("Look 20 feet away")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 4)

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(max(0, Int(until.timeIntervalSinceNow.rounded(.up))))s")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                }

                Button {
                    manager.skipRest()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Skip this break")
            }
            .padding(.horizontal, 4)
        }
    }
}
