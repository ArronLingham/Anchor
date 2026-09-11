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
    @EnvironmentObject var vm: AnchorViewModel
    @ObservedObject private var manager = EyeBreakManager.shared

    private let wingWidth: CGFloat = 140

    var body: some View {
        if case .resting(let until) = manager.phase {
            HStack(spacing: 0) {
                // Leading wing: eye icon + instruction
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)

                    Text("Look 20 feet away")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.leading, 12)
                .frame(width: wingWidth, height: vm.effectiveClosedNotchHeight, alignment: .leading)

                // Center spacer: keeps content clear of the hardware notch cutout
                Rectangle()
                    .fill(Color.black)
                    .frame(width: vm.closedNotchSize.width, height: vm.effectiveClosedNotchHeight)

                // Trailing wing: countdown + skip button
                HStack(spacing: 8) {
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
                .padding(.trailing, 12)
                .frame(width: wingWidth, height: vm.effectiveClosedNotchHeight, alignment: .trailing)
            }
            .frame(height: vm.effectiveClosedNotchHeight)
        }
    }
}
