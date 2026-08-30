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
import SwiftUI

/// Running apps arranged in a ring, selected one highlighted in the middle.
///
/// A ring rather than a row because the whole point of the shape is that every
/// entry is the same distance from the pointer, so a mouse can reach any of them
/// with one flick rather than a horizontal scan.
///
/// ## Hit-testing is a pie chart, not per-icon hover
///
/// The whole disc is divided into as many wedges as there are apps, and the
/// pointer anywhere in a wedge — not just on top of the small icon — selects
/// that app. A per-icon `.onHover` region is a target a few dozen points wide
/// at the end of a fast mouse flick; a wedge is the entire angular slice from
/// the centre hole to the outer edge, which is what makes "throw the mouse
/// roughly at the right app" work reliably.
struct AppSwitcherView: View {
    @ObservedObject private var switcher = AppSwitcherManager.shared

    /// Scales with how many apps are open — see `AppSwitcherManager.ringDiameter`.
    /// The panel's own NSWindow is sized from the same property at present
    /// time, so this must stay in lockstep with it rather than reading the
    /// raw Default directly.
    private var diameter: CGFloat { switcher.ringDiameter }

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

    /// Radius below which the pointer is treated as dead-centre rather than a
    /// wedge — otherwise a pointer sitting near the hub would noisily
    /// reassign the selection to whatever the atan2 rounding picks.
    private var deadZoneRadius: CGFloat { diameter * 0.16 }

    var body: some View {
        ZStack {
            backdrop
            wedgeHighlight

            ForEach(Array(switcher.apps.enumerated()), id: \.element.id) { index, app in
                icon(app, at: index)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard case .active(let location) = phase else { return }
            selectWedge(at: location)
        }
        .onTapGesture { location in
            selectWedge(at: location)
            switcher.activateSelection()
        }
    }

    /// Maps a point in the view's own coordinate space to the wedge it falls
    /// in, and selects it.
    ///
    /// Wedges are centred on their icon, not started at it: icon `i` sits at
    /// angle `2πi/count - π/2` (see `icon(_:at:)`), so its wedge spans a half
    /// step either side of that, and the nearest icon to the pointer's angle
    /// is found by rounding rather than flooring. Flooring would put the
    /// wedge boundary *on* each icon instead of the midpoint between two
    /// icons, silently offsetting every wedge by half a slice from the icon
    /// it's supposed to belong to — invisible while wedges were undrawn, but
    /// exactly the mismatch that would make a highlighted wedge visibly not
    /// line up with its icon.
    private func selectWedge(at point: CGPoint) {
        let count = switcher.apps.count
        guard count > 0 else { return }

        let centrePoint = CGPoint(x: diameter / 2, y: diameter / 2)
        let dx = point.x - centrePoint.x
        let dy = point.y - centrePoint.y
        guard (dx * dx + dy * dy) > deadZoneRadius * deadZoneRadius else { return }

        // atan2 is 0 at three o'clock, positive going clockwise in SwiftUI's
        // y-down space. Icons start at twelve o'clock, so rotate the reading by
        // a quarter turn before dividing into wedges.
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }

        let steps = Double(count) * angle / (2 * .pi)
        let index = Int(steps.rounded()) % count
        switcher.select(index)
    }

    /// Angle of icon `index`'s wedge centre, in the same atan2-based
    /// convention `selectWedge` reads from (0 = three o'clock, positive =
    /// clockwise in this y-down space) rotated so 0 = twelve o'clock.
    private func wedgeCentreAngle(for index: Int) -> Double {
        (Double(index) / Double(max(switcher.apps.count, 1))) * 2 * .pi - .pi / 2
    }

    private var backdrop: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(Circle().fill(.black.opacity(0.38)))
            .overlay(
                Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
    }

    /// The selected app's slice of the disc, lit up behind its icon so the
    /// ring reads as an actual pie chart rather than just a bright dot.
    @ViewBuilder
    private var wedgeHighlight: some View {
        if switcher.apps.indices.contains(switcher.selectedIndex) {
            let half = Double.pi / Double(max(switcher.apps.count, 1))
            let centre = wedgeCentreAngle(for: switcher.selectedIndex)
            WedgeShape(
                startAngle: centre - half,
                endAngle: centre + half,
                innerRadius: deadZoneRadius,
                outerRadius: diameter / 2
            )
            .fill(.white.opacity(0.14))
            .allowsHitTesting(false)
        }
    }

    /// Purely decorative now — wedge selection lives on the container, so this
    /// carries no gesture of its own and never competes with it for the touch.
    private func icon(_ app: SwitchableApp, at index: Int) -> some View {
        let isSelected = index == switcher.selectedIndex
        // Start at twelve o'clock and go clockwise, which is the direction Tab
        // advances — a ring that advanced anticlockwise would read as going
        // backwards.
        let angle = wedgeCentreAngle(for: index)
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
        .allowsHitTesting(false)
        .help(app.name)
    }
}

/// An annular sector — a donut slice from `innerRadius` to `outerRadius`,
/// sweeping `startAngle` to `endAngle` in the same y-down, atan2-based angle
/// convention the rest of this file uses (0 = three o'clock, positive =
/// clockwise). Built from sampled points along both arcs rather than
/// `Path.addArc`'s `clockwise` flag, whose sense is easy to get backwards
/// against that convention — this way the geometry can't disagree with
/// `selectWedge`'s hit-testing, since both read the same angles the same way.
private struct WedgeShape: Shape {
    let startAngle: Double
    let endAngle: Double
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func point(angle: Double, radius: CGFloat) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }

        let steps = 24
        var path = Path()
        path.move(to: point(angle: startAngle, radius: outerRadius))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            path.addLine(to: point(angle: startAngle + (endAngle - startAngle) * t, radius: outerRadius))
        }
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            path.addLine(to: point(angle: endAngle - (endAngle - startAngle) * t, radius: innerRadius))
        }
        path.closeSubpath()
        return path
    }
}
