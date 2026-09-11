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

/// The closed-notch banner for a battery, disk or CPU warning.
///
/// This view exists because the alerts had **nowhere to appear**. The manager
/// posted an `anchorSystemAlert` notification that nothing in the app observed,
/// and `enableAudioDeviceHUD`'s sibling setting promised a HUD that was never
/// built — a switch wired to a publisher with no subscriber, which is the same
/// class of failure as a settings key with no pane.
///
/// It follows `EyeBreakLiveActivity` rather than inventing a pattern: the
/// manager publishes what to show, this draws it, and `ContentView` picks it in
/// the closed-notch chain. Nothing ticks — an alert is static text until the
/// manager clears it.
struct SystemAlertLiveActivity: View {
    @EnvironmentObject var vm: AnchorViewModel
    @ObservedObject private var manager = SystemAlertManager.shared

    private let wingWidth: CGFloat = 130

    var body: some View {
        if let alert = manager.visibleAlert {
            HStack(spacing: 0) {
                // Leading wing: icon + alert title
                HStack(spacing: 6) {
                    Image(systemName: alert.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(alert.tint)

                    Text(alert.title)
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

                // Trailing wing: detail + dismiss button
                HStack(spacing: 6) {
                    Text(alert.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)

                    Button {
                        manager.dismissVisibleAlert()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(.trailing, 12)
                .frame(width: wingWidth, height: vm.effectiveClosedNotchHeight, alignment: .trailing)
            }
            .frame(height: vm.effectiveClosedNotchHeight)
        }
    }
}
