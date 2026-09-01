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

/// The stats tab. Sampling starts when this appears and stops when it leaves —
/// see SystemStatsManager on why that is not optional.
struct NotchStatsView: View {
    @ObservedObject private var stats = SystemStatsManager.shared

    var body: some View {
        HStack(spacing: 14) {
            gauge("CPU", value: stats.current.cpuPercent, unit: "%", tint: .green)
            gauge("Memory", value: stats.current.memoryPercent, unit: "%", tint: .blue)
            network
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
        .onAppear { stats.acquire() }
        .onDisappear { stats.release() }
    }

    private func gauge(_ label: String, value: Double, unit: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(1, max(0, value / 100)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
                Text("\(Int(value.rounded()))")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)

            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 6) {
            rate("arrow.down", stats.current.networkInBytesPerSecond, .cyan)
            rate("arrow.up", stats.current.networkOutBytesPerSecond, .orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rate(_ icon: String, _ bytesPerSecond: Double, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(Self.formatted(bytesPerSecond))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    /// Rates, not sizes — ByteCountFormatter's decimal units are what network
    /// throughput is conventionally quoted in.
    private static func formatted(_ bytesPerSecond: Double) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .decimal
        // Off, or a quiet link reads "Zero KB/s" instead of "0 KB/s".
        f.allowsNonnumericFormatting = false
        f.zeroPadsFractionDigits = false
        return f.string(fromByteCount: Int64(max(0, bytesPerSecond))) + "/s"
    }
}
