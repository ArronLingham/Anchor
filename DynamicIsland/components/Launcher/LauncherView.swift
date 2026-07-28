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

/// The launcher: a search field over either a filtered result list (while
/// typing) or a Launchpad-style grid of everything (when the field is empty).
struct LauncherView: View {
    let onLaunch: (LauncherApp) -> Void
    let onDismiss: () -> Void

    @ObservedObject private var index = AppIndex.shared
    @State private var query = ""
    @State private var results: [LauncherResult] = []
    @State private var selection = 0
    @State private var calculation: String?
    @State private var copiedFlash = false
    @FocusState private var queryFocused: Bool

    private static let rowHeight: CGFloat = 44

    private var showingGrid: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.5)

            if let calculation {
                calculatorRow(calculation)
            } else if showingGrid {
                LauncherGridView(
                    apps: results.map(\.app),
                    selection: $selection,
                    onLaunch: onLaunch
                )
            } else if results.isEmpty {
                emptyState
            } else {
                resultList
            }
        }
        .frame(width: 860, height: 560)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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
            Image(systemName: calculation == nil ? "magnifyingglass" : "equal.square")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search applications", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($queryFocused)
                .onSubmit(activateSelection)
                .onKeyPress(.upArrow) { move(by: -stride); return .handled }
                .onKeyPress(.downArrow) { move(by: stride); return .handled }
                .onKeyPress(.leftArrow) { showingGrid ? move(by: -1) : nil; return showingGrid ? .handled : .ignored }
                .onKeyPress(.rightArrow) { showingGrid ? move(by: 1) : nil; return showingGrid ? .handled : .ignored }
                .onKeyPress(.escape) { onDismiss(); return .handled }

            if copiedFlash {
                Text("Copied")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if index.isIndexing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
    }

    /// In the grid, ↑/↓ move a whole row; in the list they move one item.
    private var stride: Int { showingGrid ? LauncherGridView.columns : 1 }

    private func calculatorRow(_ value: String) -> some View {
        VStack(spacing: 8) {
            Text(value)
                .font(.system(size: 44, weight: .light, design: .rounded))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Text("Press ↩ to copy")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { position, result in
                        LauncherRow(result: result, isSelected: position == selection)
                            .frame(height: Self.rowHeight)
                            .id(position)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = position
                                activateSelection()
                            }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: selection) { _, new in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.app.dashed")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("No applications match “\(query)”")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Behaviour

    private func recompute() {
        calculation = CalculatorAction.evaluate(query)
        // The grid shows everything; the filtered list is capped for speed.
        results = index.search(query, limit: showingGrid ? Int.max : 40)
        if results.isEmpty {
            selection = 0
        } else {
            selection = min(selection, results.count - 1)
        }
        if showingGrid { selection = min(selection, max(0, results.count - 1)) }
    }

    private func move(by delta: Int) {
        guard calculation == nil, !results.isEmpty else { return }
        let next = selection + delta
        // Clamp in the grid so ↓ on the last row does not wrap to the start;
        // wrap in the list, where it reads as a loop through a short set.
        if showingGrid {
            selection = max(0, min(results.count - 1, next))
        } else {
            selection = (next + results.count) % results.count
        }
    }

    private func activateSelection() {
        if let calculation {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(calculation, forType: .string)
            withAnimation { copiedFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation { copiedFlash = false }
            }
            return
        }
        guard results.indices.contains(selection) else { return }
        onLaunch(results[selection].app)
    }
}

/// One result row: icon, name with matched characters emphasised, path hint.
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
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
                .padding(.horizontal, 10)
        )
        .onAppear(perform: loadIcon)
    }

    /// Bolds the characters the query actually matched.
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
        if let cached = AppIconCache.shared.icon(for: result.app, completion: { icon = $0 }) {
            icon = cached
        }
    }
}
