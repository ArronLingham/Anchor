/*
 * Atoll (DynamicIsland)
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

/// Notch live activity for the Claude usage window: an hourglass on the left
/// wing, the countdown to the reset on the right.
///
/// This observes `ClaudeUsageManager.shared.live` — the leaf object — and never
/// the manager itself. `remaining` changes once a second for as long as the
/// window is closed, which can be hours; hanging that off the manager would
/// re-render every view that observes it, `ContentView` included.
///
/// It also tells the manager when it is on screen, because the per-second timer
/// exists only to drive this readout and is stopped whenever nothing shows it.
struct ClaudeUsageLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var live = ClaudeUsageManager.shared.live

    private let wingSpacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            leadingWing
                .frame(width: wingWidth, height: vm.effectiveClosedNotchHeight)

            Rectangle()
                .fill(Color.black)
                .frame(width: vm.closedNotchSize.width)

            trailingWing
                .frame(width: wingWidth, height: vm.effectiveClosedNotchHeight)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .onAppear { ClaudeUsageManager.shared.setCountdownVisible(true) }
        .onDisappear { ClaudeUsageManager.shared.setCountdownVisible(false) }
    }

    // MARK: - Wings

    private var leadingWing: some View {
        HStack(spacing: wingSpacing) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: live.phase == .resuming)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
    }

    @ViewBuilder
    private var trailingWing: some View {
        HStack(spacing: wingSpacing) {
            Spacer(minLength: 0)

            switch live.phase {
            case .limited:
                Text(countdownText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            case .resuming:
                Text("Resuming…")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            case .resumed:
                Text("Claude is back")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.green)
                    .lineLimit(1)
            case .idle:
                EmptyView()
            }
        }
        .padding(.trailing, 10)
        .animation(.smooth(duration: 0.2), value: live.phase)
    }

    // MARK: - Derived state

    private var wingWidth: CGFloat {
        max(60, (vm.closedNotchSize.width * 0.6))
    }

    private var iconName: String {
        switch live.phase {
        case .limited: return "hourglass"
        case .resuming: return "arrow.clockwise"
        case .resumed: return "checkmark.circle.fill"
        case .idle: return "hourglass"
        }
    }

    private var tint: Color {
        switch live.phase {
        case .limited: return .orange
        case .resuming: return .white
        case .resumed: return .green
        case .idle: return .white
        }
    }

    private var countdownText: String {
        "Claude resets in \(Self.durationText(live.remaining))"
    }

    private var accessibilityDescription: String {
        switch live.phase {
        case .idle: return ""
        case .limited: return countdownText
        case .resuming: return String(localized: "Resuming Claude")
        case .resumed: return String(localized: "Claude usage window has reset")
        }
    }

    /// Coarse above ten minutes, second-by-second below it. There is no point
    /// redrawing "4h 12m" once a second, and no point hiding the last seconds.
    static func durationText(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes >= 10 { return "\(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}
