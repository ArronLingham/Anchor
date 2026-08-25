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
import Defaults
import SwiftUI

/// The Launchpad replacement: a paged grid of every installed application,
/// shown when the search field is empty.
///
/// Deliberately no drag-to-reorder or folders in this version. Both are
/// achievable but a paged, reorderable, folder-forming SwiftUI grid is a large
/// amount of fiddly state for something you can also just search — and the
/// layout could not be migrated from the old Launchpad anyway, since macOS 26
/// removed the database it was stored in.
struct LauncherGridView: View {
    let apps: [LauncherApp]
    @Binding var selection: Int
    let onLaunch: (LauncherApp) -> Void

    static var columns: Int { max(3, min(12, Defaults[.launcherGridColumns])) }
    static var rows: Int { max(2, min(8, Defaults[.launcherGridRows])) }
    static var perPage: Int { columns * rows }

    private var pages: [[LauncherApp]] {
        stride(from: 0, to: apps.count, by: Self.perPage).map {
            Array(apps[$0..<min($0 + Self.perPage, apps.count)])
        }
    }

    private var currentPage: Int {
        guard Self.perPage > 0 else { return 0 }
        return selection / Self.perPage
    }

    var body: some View {
        VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, page in
                            page_(page, pageIndex: pageIndex)
                                .id(pageIndex)
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .onChange(of: currentPage) { _, page in
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(page, anchor: .center) }
                }
            }

            if pages.count > 1 {
                pageDots
            }
        }
        .padding(.vertical, 12)
    }

    private func page_(_ page: [LauncherApp], pageIndex: Int) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 4), count: Self.columns),
            spacing: 4
        ) {
            ForEach(Array(page.enumerated()), id: \.element.id) { offset, app in
                let absolute = pageIndex * Self.perPage + offset
                LauncherGridCell(app: app, isSelected: absolute == selection)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = absolute
                        onLaunch(app)
                    }
            }
        }
        .padding(.horizontal, 20)
    }

    /// Dots are clickable — jumping five pages with the arrow keys is tedious,
    /// and a dot that looks like a control but isn't one reads as broken.
    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pages.count, id: \.self) { index in
                Circle()
                    .fill(index == currentPage ? Color.primary.opacity(0.75) : Color.primary.opacity(0.2))
                    .frame(width: 6, height: 6)
                    // Padded hit area — a 6pt target is too small to click.
                    .padding(4)
                    .contentShape(Circle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = index * Self.perPage
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentPage)
    }
}

/// One app tile: icon above a wrapped, centred name.
private struct LauncherGridCell: View {
    let app: LauncherApp
    let isSelected: Bool

    @State private var icon: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 56, height: 56)

            Text(app.name)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 28, alignment: .top)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
                )
        )
        .scaleEffect(isSelected ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .onAppear(perform: loadIcon)
    }

    private func loadIcon() {
        guard icon == nil else { return }
        if let cached = AppIconCache.shared.icon(for: app, completion: { icon = $0 }) {
            icon = cached
        }
    }
}
