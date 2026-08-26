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

/// Recent macOS notifications, mirrored into the notch.
///
/// A leaf view observing `NotificationMirrorManager` directly, so an arriving
/// notification re-renders this list rather than the whole notch.
struct NotchNotificationsView: View {
    @ObservedObject private var manager = NotificationMirrorManager.shared

    var body: some View {
        switch manager.state {
        case .running:
            if manager.recent.isEmpty {
                message("Nothing yet. New notifications will appear here.")
            } else {
                list
            }
        case .needsPermission:
            message("Needs Full Disk Access. Grant it in Settings → Live Activities.")
        case .off:
            message("Notification mirroring is off.")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(manager.recent) { item in
                    row(item)
                    if item.id != manager.recent.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func row(_ item: MirroredNotification) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let icon = AppIconAsNSImage(for: item.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "bell.fill")
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let body = item.body {
                    Text(body)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
        .help(item.appName)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
