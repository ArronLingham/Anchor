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
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                gauge("CPU", value: stats.current.cpuPercent, tint: .green)
                gauge("GPU", value: stats.current.gpuPercent, tint: .purple)
                gauge("Memory", value: stats.current.memoryTotalBytes > 0 ? stats.current.memoryPercent : nil, tint: .blue)
                VStack(alignment: .leading, spacing: 6) {
                    rate("arrow.down", stats.current.networkInBytesPerSecond, .cyan)
                    rate("arrow.up", stats.current.networkOutBytesPerSecond, .orange)
                }
            }
            HStack(spacing: 16) {
                temperature("CPU", stats.current.cpuTemperature)
                temperature("GPU", stats.current.gpuTemperature)
                temperature("Battery", stats.current.batteryTemperature)
                if let charge = stats.current.batteryPercent {
                    Text("\(charge)% \(stats.current.charging ? "charging" : "battery")")
                }
                if let watts = stats.current.batteryWatts {
                    Text("\(abs(watts), specifier: "%.1f") W")
                }
            }
            Text("Memory pressure: \(stats.current.memoryPressure)")
                .foregroundStyle(stats.current.memoryPressure == "Critical" ? .red : .secondary)
        }
        .font(.system(size: 11)).monospacedDigit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
        .onAppear { stats.acquire() }
        .onDisappear { stats.release() }
    }

    private func temperature(_ name: String, _ value: Double?) -> some View {
        Text(value.map { "\(name) \(Int($0.rounded()))°C" } ?? "\(name) —")
            .foregroundStyle(.secondary)
    }

    private func gauge(_ label: String, value: Double?, tint: Color) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(1, max(0, (value ?? 0) / 100)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
                Text(value.map { String(Int($0.rounded())) } ?? "—")
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

    private func rate(_ icon: String, _ bytesPerSecond: Double?, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(bytesPerSecond.map(Self.formatted) ?? "Measuring…")
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
