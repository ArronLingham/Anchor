/*
 * Anchor
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

/// A small ⓘ that opens an explanation of the setting beside it.
///
/// This exists because the explanations were already written — 53 settings
/// carried `.help()` text — and `.help()` only surfaces on a hover held long
/// enough for the tooltip to appear. Nobody discovers a setting that way. The
/// same string is now clickable, and still available on hover.
struct SettingsInfoButton: View {
    let text: String

    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
                .padding(12)
        }
        .accessibilityLabel(Text("About this setting"))
    }
}

extension View {
    /// Adds a clickable explanation to a settings row.
    ///
    /// Placed after the row's own control rather than beside its label: a Form
    /// row hands its trailing edge to the control (a switch, a picker), and
    /// rebuilding every row as a `LabeledContent` to make space would be a far
    /// larger change than this earns.
    func settingsInfo(_ text: String) -> some View {
        HStack(spacing: 6) {
            self
            SettingsInfoButton(text: text)
        }
    }
}
