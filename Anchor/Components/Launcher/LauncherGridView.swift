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
    @Default(.launcherNavigationStyle) private var navigationStyle
    @Default(.launcherSortMode) private var sortMode
    @State private var draggingID: String?
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

            if pages.count > 1 && navigationStyle.showsDots {
                pageDots
            }
            if pages.count > 1 && navigationStyle.showsBar {
                pageScrubber
            }
        }
        .padding(.vertical, 12)
        // Moving the pointer to either edge pages, the way Launchpad did.
        //
        // The grid stopped dead at the right edge before: with a paging scroll
        // view there is nothing to drag against, so reaching the edge did
        // nothing and the only way forward was the keyboard or the dots.
        .overlay(alignment: .trailing) { edgeAdvance(forward: true) }
        .overlay(alignment: .leading) { edgeAdvance(forward: false) }
    }

    /// A narrow hover strip at the screen edge that advances a page.
    ///
    /// Hover rather than click: the pointer is already travelling that way when
    /// it runs out of grid, and a click target that thin is hard to hit. It
    /// re-arms only after the pointer leaves, so resting there does not run
    /// through every page.
    @ViewBuilder
    private func edgeAdvance(forward: Bool) -> some View {
        let canGo = forward ? currentPage < pages.count - 1 : currentPage > 0
        if pages.count > 1 {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 46)
                .contentShape(Rectangle())
                .onHover { inside in
                    guard inside, canGo else { return }
                    let target = forward ? currentPage + 1 : currentPage - 1
                    selection = target * Self.perPage
                }
                .allowsHitTesting(canGo)
                .accessibilityHidden(true)
        }
    }

    /// A draggable bar, for people who would rather scrub than click dots.
    private var pageScrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = pages.count > 1 ? Double(currentPage) / Double(pages.count - 1) : 0
            let knobWidth = max(40, width / Double(pages.count))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 4)
                Capsule()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: knobWidth, height: 4)
                    .offset(x: (width - knobWidth) * fraction)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let p = max(0, min(1, drag.location.x / max(width, 1)))
                    let target = Int((p * Double(pages.count - 1)).rounded())
                    if target != currentPage { selection = target * Self.perPage }
                })
        }
        .frame(height: 12)
        .padding(.horizontal, 60)
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
                    // Dragging only means something when the order is the
                    // user's to set. Under any other sort mode the position is
                    // derived, so letting someone drag would either be ignored
                    // or silently switch their sort — both worse than the
                    // gesture simply not being offered.
                    .opacity(draggingID == app.id ? 0.35 : 1)
                    .modifier(ReorderableCell(
                        enabled: sortMode.isReorderable,
                        appID: app.id,
                        draggingID: $draggingID,
                        onDrop: { moved in reorder(moved, before: app.id) }))
            }
        }
        .padding(.horizontal, 20)
    }

    /// Moves `moved` to sit immediately before `target` in the custom order.
    ///
    /// The stored order only has to contain what has actually been placed, so
    /// this seeds it from the current on-screen order the first time — without
    /// that, dragging one icon would send every unplaced app to the back.
    private func reorder(_ moved: String, before target: String) {
        guard sortMode.isReorderable, moved != target else { return }
        var order = Defaults[.launcherCustomOrder]
        if order.isEmpty { order = apps.map(\.id) }
        order.removeAll { $0 == moved }
        if let idx = order.firstIndex(of: target) {
            order.insert(moved, at: idx)
        } else {
            order.append(moved)
        }
        Defaults[.launcherCustomOrder] = order
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


/// Drag-to-reorder, applied only when the sort mode makes it meaningful.
///
/// A modifier rather than inline `if`, because attaching `.draggable` to one
/// branch and not the other changes the view's identity and SwiftUI drops the
/// cell's state mid-drag.
private struct ReorderableCell: ViewModifier {
    let enabled: Bool
    let appID: String
    @Binding var draggingID: String?
    let onDrop: (String) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    draggingID = appID
                    return NSItemProvider(object: appID as NSString)
                }
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                        guard let moved = value as? String else { return }
                        DispatchQueue.main.async {
                            onDrop(moved)
                            draggingID = nil
                        }
                    }
                    return true
                }
        } else {
            content
        }
    }
}
