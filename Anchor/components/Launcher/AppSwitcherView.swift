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

import AppKit
import Defaults
import SwiftUI

/// Running apps arranged in a ring, selected one highlighted in the middle.
///
/// A ring rather than a row because the whole point of the shape is that every
/// entry is the same distance from the pointer, so a mouse can reach any of them
/// with one flick rather than a horizontal scan.
struct AppSwitcherView: View {
    @ObservedObject private var switcher = AppSwitcherManager.shared
    @Default(.appSwitcherRingDiameter) private var diameter

    /// Icon edge, shrinking as the ring fills up so a busy Mac still fits.
    private var iconSize: CGFloat {
        let count = switcher.apps.count
        switch count {
        case ...8: return 64
        case 9...12: return 54
        case 13...18: return 44
        default: return 36
        }
    }

    private var radius: CGFloat { (diameter / 2) - iconSize * 0.75 }

    var body: some View {
        ZStack {
            backdrop

            ForEach(Array(switcher.apps.enumerated()), id: \.element.id) { index, app in
                icon(app, at: index)
            }

            centre
        }
        .frame(width: diameter, height: diameter)
    }

    private var backdrop: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(
                Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    /// Name of the highlighted app, in the hole in the middle of the ring.
    @ViewBuilder
    private var centre: some View {
        if switcher.apps.indices.contains(switcher.selectedIndex) {
            let app = switcher.apps[switcher.selectedIndex]
            VStack(spacing: 3) {
                Text(app.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(switcher.selectedIndex + 1) of \(switcher.apps.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: diameter * 0.42)
        }
    }

    private func icon(_ app: SwitchableApp, at index: Int) -> some View {
        let isSelected = index == switcher.selectedIndex
        // Start at twelve o'clock and go clockwise, which is the direction Tab
        // advances — a ring that advanced anticlockwise would read as going
        // backwards.
        let angle = (Double(index) / Double(max(switcher.apps.count, 1)))
            * 2 * .pi - .pi / 2
        let offset = CGSize(
            width: cos(angle) * radius,
            height: sin(angle) * radius)

        return ZStack {
            if isSelected {
                Circle()
                    .fill(.white.opacity(0.16))
                    .frame(width: iconSize * 1.42, height: iconSize * 1.42)
            }

            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: iconSize, height: iconSize)
        }
        .scaleEffect(isSelected ? 1.12 : 1)
        .offset(offset)
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: switcher.selectedIndex)
        .onTapGesture {
            switcher.select(index)
            switcher.activateSelection()
        }
        .onHover { inside in
            // Hover selects, so a mouse user never has to Tab round the ring.
            if inside { switcher.select(index) }
        }
        .help(app.name)
    }
}
