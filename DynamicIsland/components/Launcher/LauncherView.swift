/*
 * Atoll (DynamicIsland)
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

/// The launcher's search UI: a query field over a ranked result list.
struct LauncherView: View {
    let onLaunch: (LauncherApp) -> Void
    let onDismiss: () -> Void

    @ObservedObject private var index = AppIndex.shared
    @State private var query = ""
    @State private var results: [LauncherResult] = []
    @State private var selection = 0
    @FocusState private var queryFocused: Bool

    private static let rowHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if !results.isEmpty {
                Divider().opacity(0.5)
                resultList
            } else if !query.isEmpty {
                emptyState
            }
        }
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onAppear {
            index.refreshIfNeeded()
            recompute()
            queryFocused = true
        }
        .onChange(of: query) { _, _ in recompute() }
        .onChange(of: index.apps) { _, _ in recompute() }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search applications", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($queryFocused)
                .onSubmit(launchSelected)
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.escape) { onDismiss(); return .handled }

            if index.isIndexing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { position, result in
                        LauncherRow(
                            result: result,
                            isSelected: position == selection
                        )
                        .frame(height: Self.rowHeight)
                        .id(position)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = position
                            launchSelected()
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: Self.rowHeight * 8)
            .onChange(of: selection) { _, new in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.app.dashed")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No applications match “\(query)”")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Behaviour

    private func recompute() {
        results = index.search(query)
        selection = results.isEmpty ? 0 : min(selection, results.count - 1)
        if query.isEmpty { selection = 0 }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        // Wrap, so holding ↓ at the bottom returns to the top.
        selection = (selection + delta + results.count) % results.count
    }

    private func launchSelected() {
        guard results.indices.contains(selection) else { return }
        onLaunch(results[selection].app)
    }
}

/// One result row: icon, name with matched characters emphasised, and path hint.
private struct LauncherRow: View {
    let result: LauncherResult
    let isSelected: Bool

    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                highlightedName
                    .font(.system(size: 14))
                    .lineLimit(1)
                Text(locationHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
                .padding(.horizontal, 8)
        )
        .onAppear(perform: loadIcon)
    }

    /// Bolds the characters that the query actually matched.
    private var highlightedName: Text {
        let matched = Set(result.matchedIndices)
        guard !matched.isEmpty else { return Text(result.app.name) }

        var composed = Text("")
        for (offset, character) in result.app.name.enumerated() {
            let piece = Text(String(character))
            composed =
                composed
                + (matched.contains(offset)
                    ? piece.fontWeight(.bold).foregroundColor(.primary)
                    : piece.foregroundColor(.secondary))
        }
        return composed
    }

    private var locationHint: String {
        result.app.url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func loadIcon() {
        guard icon == nil else { return }
        if let cached = AppIconCache.shared.icon(for: result.app, completion: { loaded in
            icon = loaded
        }) {
            icon = cached
        }
    }
}
