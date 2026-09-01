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

/// What the battery reports about itself — cycles, capacity, condition.
///
/// Read once when this appears. None of these values move on a timescale worth
/// polling for: cycle count changes a few times a week and capacity a few times
/// a year.
struct BatteryHealthView: View {
    @State private var health: MacBatteryManager.BatteryHealth?

    var body: some View {
        Group {
            if let health {
                VStack(alignment: .leading, spacing: 6) {
                    row("Condition", health.condition,
                        warn: health.condition != "Normal")
                    if let percent = health.healthPercent {
                        row("Maximum capacity", "\(percent)%", warn: percent < 80)
                    }
                    row("Cycle count", "\(health.cycleCount)")
                    row("Capacity",
                        "\(health.nominalCapacity) of \(health.designCapacity) mAh")
                    if health.temperature > 0 {
                        row("Temperature",
                            String(format: "%.1f °C", health.temperature))
                    }
                }
            } else {
                Text("No battery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { health = MacBatteryManager.shared.currentHealth() }
    }

    private func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(warn ? Color.orange : Color.primary)
        }
    }
}
