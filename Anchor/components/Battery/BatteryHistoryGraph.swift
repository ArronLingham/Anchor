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

/// Battery level over the last 24 hours.
///
/// A leaf view observing `BatteryHistoryManager` directly, so a new sample does
/// not re-render anything else. Drawn as a single `Path` rather than one shape
/// per point — hundreds of stacked views would cost far more than the line is
/// worth.
struct BatteryHistoryGraph: View {
    @ObservedObject private var history = BatteryHistoryManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if history.samples.count < 2 {
                Text("Collecting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                graph
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Last 24 hours")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let net = history.netChange {
                Text(net >= 0 ? "+\(Int(net))%" : "\(Int(net))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(net >= 0 ? .green : .orange)
            }
        }
    }

    private var graph: some View {
        GeometryReader { geo in
            let samples = history.samples
            if let first = samples.first, let last = samples.last {
                let span = max(last.at.timeIntervalSince(first.at), 1)
                let points = samples.map { sample -> CGPoint in
                    CGPoint(
                        x: geo.size.width * (sample.at.timeIntervalSince(first.at) / span),
                        y: geo.size.height * (1 - CGFloat(sample.level) / 100)
                    )
                }

                ZStack {
                    // Fill under the line, so the shape reads at a glance.
                    Path { path in
                        guard let start = points.first, let end = points.last else { return }
                        path.move(to: CGPoint(x: start.x, y: geo.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: end.x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [.green.opacity(0.28), .green.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                    Path { path in
                        guard let start = points.first else { return }
                        path.move(to: start)
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(.green, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
        .frame(height: 60)
    }
}
