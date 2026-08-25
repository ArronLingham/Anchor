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

/// Recently picked colours. Click one to copy it again.
///
/// A leaf view observing `ColorPickerManager` directly, so picking a colour
/// does not invalidate the whole settings form.
struct ColorPickerHistoryStrip: View {
    @ObservedObject private var manager = ColorPickerManager.shared

    private let columns = [GridItem(.adaptive(minimum: 34), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !manager.history.isEmpty {
                    Button("Clear") { manager.clearHistory() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if manager.history.isEmpty {
                Text("Nothing picked yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(manager.history) { picked in
                        Button {
                            manager.copy(picked)
                        } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(picked.color)
                                .frame(height: 34)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("\(picked.hexString) — click to copy")
                    }
                }
            }
        }
    }
}
