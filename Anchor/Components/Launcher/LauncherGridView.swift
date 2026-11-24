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
import AnchorUtilities
import Defaults
import SwiftUI

/// The shared horizontal pager for categories and the application grid.
struct LauncherGridView: View {
    let apps: [LauncherApp]
    /// Folder name -> its apps, resolved by the caller. Drawn before the loose
    /// apps, and deliberately NOT part of `selection`: folders are opened with
    /// the mouse, while the arrow keys and Return continue to address apps, so
    /// keyboard navigation means the same thing whether or not folders exist.
    var folders: [(name: String, apps: [LauncherApp])] = []
    /// Whether dragging may reorder. False while a query is filtering the grid:
    /// the order seeds from what is on screen, so a drag among search results
    /// would write an order containing only the matches and permanently demote
    /// everything that did not match that one query.
    var allowsReorder: Bool = true
    @Binding var selection: Int
    let currentPage: Int
    let keyboardSelection: Int?
    let includesCategories: Bool
    let widgetProfileID: String
    let onPageChanged: (Int) -> Void
    let onLayoutChanged: (LauncherGridLayout) -> Void
    let onOpenCategory: (AppCategory) -> Void
    @Default(.launcherNavigationStyle) private var navigationStyle
    @Default(.launcherSortMode) private var sortMode
    @State private var draggingID: String?
    @State private var openFolder: String?
    @State private var renaming: String = ""
    let onLaunch: (LauncherApp) -> Void
    @State private var scrollPosition: ScrollPosition
    @State private var isScrubbing = false
    @State private var isScrubberHovered = false

    init(
        apps: [LauncherApp],
        folders: [(name: String, apps: [LauncherApp])],
        allowsReorder: Bool,
        selection: Binding<Int>,
        currentPage: Int,
        keyboardSelection: Int?,
        includesCategories: Bool,
        widgetProfileID: String,
        onPageChanged: @escaping (Int) -> Void,
        onLayoutChanged: @escaping (LauncherGridLayout) -> Void,
        onOpenCategory: @escaping (AppCategory) -> Void,
        onLaunch: @escaping (LauncherApp) -> Void
    ) {
        self.apps = apps
        self.folders = folders
        self.allowsReorder = allowsReorder
        _selection = selection
        self.currentPage = currentPage
        self.keyboardSelection = keyboardSelection
        self.includesCategories = includesCategories
        self.widgetProfileID = widgetProfileID
        self.onPageChanged = onPageChanged
        self.onLayoutChanged = onLayoutChanged
        self.onOpenCategory = onOpenCategory
        self.onLaunch = onLaunch
        _scrollPosition = State(initialValue: ScrollPosition(id: currentPage, anchor: .center))
    }

    /// One grid slot: a folder tile or an app.
    private enum Slot: Identifiable {
        case folder(name: String, apps: [LauncherApp])
        case app(LauncherApp, index: Int)

        var id: String {
            switch self {
            case .folder(let name, _): return "folder:" + name
            case .app(let app, _): return app.id
            }
        }
    }

    private var slots: [Slot] {
        folders.map { Slot.folder(name: $0.name, apps: $0.apps) }
            + apps.enumerated().map { Slot.app($1, index: $0) }
    }

    private func pages(for layout: LauncherGridLayout) -> [[Slot]] {
        let all = slots
        let perPage = layout.perPage
        guard perPage > 0, !all.isEmpty else { return [] }
        return stride(from: 0, to: all.count, by: perPage).map {
            Array(all[$0..<min($0 + perPage, all.count)])
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = LauncherGridLayout.calculate(for: geometry.size)
            let pageList = pages(for: layout)
            let appPageCount = max(1, pageList.count)
            let pageIDs = LauncherPaging.pageIDs(appPageCount: appPageCount, showCategories: includesCategories)

            VStack(spacing: 10) {
                GeometryReader { viewport in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(pageIDs, id: \.self) { page in
                                Group {
                                    if page == LauncherPaging.categoriesPage {
                                        LauncherCategoryPageView(
                                            widgetProfileID: widgetProfileID,
                                            appPageCount: appPageCount,
                                            isPageActive: page == currentPage,
                                            onOpenCategory: onOpenCategory,
                                            onLaunch: onLaunch
                                        )
                                    } else {
                                        appPage(
                                            pageList.indices.contains(page) ? pageList[page] : [],
                                            index: page,
                                            appPageCount: appPageCount,
                                            layout: layout,
                                            height: viewport.size.height
                                        )
                                    }
                                }
                                .frame(width: viewport.size.width, height: viewport.size.height)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition($scrollPosition, anchor: .center)
                    .scrollIndicators(.never)
                    .onChange(of: scrollPosition.viewID(type: Int.self)) { _, page in
                        guard scrollPosition.isPositionedByUser, let page, page != currentPage else { return }
                        onPageChanged(page)
                    }
                    .onChange(of: currentPage) { _, page in
                        guard scrollPosition.viewID(type: Int.self) != page else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scrollPosition.scrollTo(id: page, anchor: .center)
                        }
                    }
                    .overlay(alignment: .trailing) { edgeAdvance(forward: true, pageIDs: pageIDs) }
                    .overlay(alignment: .leading) { edgeAdvance(forward: false, pageIDs: pageIDs) }
                }

                navigationControls(pageIDs: pageIDs)
            }
            .padding(.vertical, 12)
            .overlay { folderOverlay }
            .onChange(of: layout, initial: true) { _, layout in onLayoutChanged(layout) }
        }
    }

    @ViewBuilder
    private var folderOverlay: some View {
        if let name = openFolder,
           let members = folders.first(where: { $0.name == name })?.apps {
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .ignoresSafeArea()
                    .onTapGesture { openFolder = nil }
                    // Dropping an app on the backdrop moves it out of the folder.
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        accept(providers) { moved in
                            removeFromFolder(moved, folder: name)
                        }
                    }

                VStack(spacing: 14) {
                    HStack {
                        Spacer()
                        TextField("Folder name", text: $renaming)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 260)
                            .onSubmit { renameFolder(from: name, to: renaming) }
                        Spacer()
                        Button {
                            openFolder = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(5, max(1, members.count))),
                        spacing: 12
                    ) {
                        ForEach(members) { app in
                            LauncherGridCell(app: app, isSelected: false)
                                .contentShape(Rectangle())
                                .onTapGesture { onLaunch(app) }
                                .onDrag {
                                    draggingID = app.id
                                    return NSItemProvider(object: app.id as NSString)
                                }
                                .contextMenu {
                                    Button("Move out of folder") {
                                        removeFromFolder(app.id, folder: name)
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: 540)

                    Text("Drag an app outside the card to remove it from this folder.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: AnchorCorners.rectangle(cornerRadius: 22))
                .anchorCornerContainer(radius: 22)
                .overlay {
                    AnchorCorners.rectangle(cornerRadius: 22)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(radius: 30, y: 10)
                .frame(maxWidth: 620)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .onAppear { renaming = name }
        }
    }

    private func renameFolder(from old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != old else { return }
        var folders = Defaults[.launcherFolders]
        guard folders[trimmed] == nil, let members = folders[old] else { return }
        folders[trimmed] = members
        folders[old] = nil
        Defaults[.launcherFolders] = folders
        openFolder = trimmed
    }

    /// Advancing between app pages during a drag keeps the drop targets reachable.
    @ViewBuilder
    private func edgeAdvance(forward: Bool, pageIDs: Range<Int>) -> some View {
        let page = currentPage + (forward ? 1 : -1)
        if draggingID != nil, pageIDs.contains(page), page != LauncherPaging.categoriesPage {
            PageDropZone(forward: forward, onNavigate: { onPageChanged(page) })
        }
    }

    private func navigationControls(pageIDs: Range<Int>) -> some View {
        VStack(spacing: 8) {
            if navigationStyle.showsBar {
                pageScrubber(pageIDs: pageIDs)
            }
            if navigationStyle.showsDots {
                pageDots(pageIDs: pageIDs)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    /// A macOS-styled draggable scroll bar for smooth page scrubbing.
    private func pageScrubber(pageIDs: Range<Int>) -> some View {
        let totalPages = pageIDs.count
        return GeometryReader { geo in
            let barWidth: CGFloat = min(320, max(180, geo.size.width * 0.35))
            let totalAvailable = barWidth
            let knobWidth: CGFloat = totalPages > 1 ? max(44, totalAvailable / CGFloat(totalPages)) : totalAvailable
            let fraction: CGFloat = totalPages > 1 ? CGFloat(currentPage - pageIDs.lowerBound) / CGFloat(totalPages - 1) : 0
            let knobOffset = (totalAvailable - knobWidth) * fraction

            HStack {
                Spacer()
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(Color.primary.opacity(isScrubberHovered || isScrubbing ? 0.16 : 0.10))
                        .frame(width: totalAvailable, height: isScrubberHovered || isScrubbing ? 8 : 6)
                        .animation(.easeInOut(duration: 0.15), value: isScrubberHovered)

                    // Thumb
                    Capsule()
                        .fill(Color.primary.opacity(isScrubbing ? 0.85 : (isScrubberHovered ? 0.70 : 0.50)))
                        .frame(width: knobWidth, height: isScrubberHovered || isScrubbing ? 8 : 6)
                        .offset(x: knobOffset)
                        .shadow(color: Color.black.opacity(isScrubbing ? 0.25 : 0.10), radius: 2, y: 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: currentPage)
                }
                .frame(width: totalAvailable, height: 16)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isScrubberHovered = hovering
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            isScrubbing = true
                            guard totalPages > 1 else { return }
                            let page = page(at: drag.location.x, trackWidth: totalAvailable, pages: pageIDs)
                            if page != currentPage { onPageChanged(page) }
                        }
                        .onEnded { _ in
                            isScrubbing = false
                        }
                )
                .launcherWidgetPageDrop(
                    profileID: widgetProfileID,
                    pageAt: { page(at: $0.x, trackWidth: totalAvailable, pages: pageIDs) },
                    onMove: onPageChanged
                )
                Spacer()
            }
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Launchpad pages")
        .accessibilityValue(pageLabel(currentPage))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                if pageIDs.contains(currentPage + 1) { onPageChanged(currentPage + 1) }
            case .decrement:
                if pageIDs.contains(currentPage - 1) { onPageChanged(currentPage - 1) }
            @unknown default:
                break
            }
        }
    }

    private func page(at x: CGFloat, trackWidth: CGFloat, pages: Range<Int>) -> Int {
        let fraction = max(0, min(1, x / trackWidth))
        return pages.lowerBound + Int((fraction * CGFloat(pages.count - 1)).rounded())
    }

    private func appPage(
        _ slots: [Slot], index: Int, appPageCount: Int, layout: LauncherGridLayout, height: CGFloat
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if allowsReorder {
                        LauncherWidgetShelf(
                            profileID: widgetProfileID,
                            page: index,
                            appPageCount: appPageCount,
                            showCategories: includesCategories,
                            isPageActive: index == currentPage
                        )
                    }
                    appTiles(slots, layout: layout, height: height)
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .onChange(of: index == currentPage ? keyboardSelection : nil, initial: true) { _, selection in
                guard let selection, apps.indices.contains(selection) else { return }
                proxy.scrollTo(apps[selection].id)
            }
        }
    }

    private func appTiles(_ slots: [Slot], layout: LauncherGridLayout, height: CGFloat) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 4), count: layout.columns),
            spacing: layout.rows > 1
                ? min(24, max(4, (height - CGFloat(layout.rows) * 106) / CGFloat(layout.rows - 1))) : 4
        ) {
            ForEach(slots) { slot in
                switch slot {
                case .folder(let name, let members):
                    LauncherFolderCell(name: name, apps: members)
                        .frame(height: 106)
                        .contentShape(Rectangle())
                        .onTapGesture { openFolder = name }
                        // Dropping an app on a folder files it there.
                        .onDrop(of: [.text], isTargeted: nil) { providers in
                            accept(providers) { moved in addToFolder(moved, folder: name) }
                        }
                case .app(let app, let index):
                    LauncherGridCell(app: app, isSelected: index == selection)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = index
                            onLaunch(app)
                        }
                    // Dragging only means something when the order is the
                    // user's to set. Under any other sort mode the position is
                    // derived, so letting someone drag would either be ignored
                    // or silently switch their sort — both worse than the
                    // gesture simply not being offered.
                    .opacity(draggingID == app.id ? 0.35 : 1)
                    .modifier(ReorderableCell(
                        enabled: sortMode.isReorderable && allowsReorder,
                        appID: app.id,
                        draggingID: $draggingID,
                        onDrop: { moved in dropped(moved, onto: app.id) }))
                    .id(app.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Reads one dragged app id off the pasteboard and hands it to `action`.
    private func accept(_ providers: [NSItemProvider], _ action: @escaping (String) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let moved = value as? String else { return }
            DispatchQueue.main.async {
                action(moved)
                draggingID = nil
            }
        }
        return true
    }

    /// An app dropped on another app: reorder, or make a folder of the two.
    ///
    /// Holding a modifier is what separates them. Dropping one icon onto
    /// another is far more often a reorder than a filing, and a gesture that
    /// silently swallowed two apps into a folder would be much harder to undo
    /// than one that put them in the wrong order.
    private func dropped(_ moved: String, onto target: String) {
        if NSEvent.modifierFlags.contains(.option) {
            makeFolder(moved, target)
        } else {
            reorder(moved, before: target)
        }
    }

    private func makeFolder(_ a: String, _ b: String) {
        guard a != b else { return }
        var folders = Defaults[.launcherFolders]
        // A name the user will rename; numbered so a second one does not
        // collide with the first.
        var name = String(localized: "New Folder")
        var n = 2
        while folders[name] != nil { name = String(localized: "New Folder \(n)"); n += 1 }
        folders[name] = [b, a]
        Defaults[.launcherFolders] = folders
    }

    private func addToFolder(_ appID: String, folder: String) {
        var folders = Defaults[.launcherFolders]
        // Out of any folder it was already in, so an app is never in two.
        for (key, value) in folders where value.contains(appID) {
            folders[key] = value.filter { $0 != appID }
        }
        var members = folders[folder] ?? []
        if !members.contains(appID) { members.append(appID) }
        folders[folder] = members
        folders = folders.filter { !$0.value.isEmpty }
        Defaults[.launcherFolders] = folders
    }

    private func removeFromFolder(_ appID: String, folder: String) {
        var folders = Defaults[.launcherFolders]
        folders[folder] = (folders[folder] ?? []).filter { $0 != appID }
        // A folder with nothing in it is just a tile in the way.
        folders = folders.filter { !$0.value.isEmpty }
        Defaults[.launcherFolders] = folders
        if folders[folder] == nil { openFolder = nil }
    }

    /// Moves `moved` to sit immediately before `target` in the custom order.
    ///
    /// The stored order only has to contain what has actually been placed, so
    /// this seeds it from the current on-screen order the first time — without
    /// that, dragging one icon would send every unplaced app to the back.
    private func reorder(_ moved: String, before target: String) {
        guard sortMode.isReorderable, allowsReorder, moved != target else { return }
        var order = Defaults[.launcherCustomOrder]
        // Seed from the WHOLE index, not from `apps` — that is only what this
        // view is currently showing, so seeding from it would write an order
        // containing a subset and push every app missing from it to the back.
        if order.isEmpty { order = AppIndex.shared.apps.map(\.id) }
        order.removeAll { $0 == moved }
        if let idx = order.firstIndex(of: target) {
            order.insert(moved, at: idx)
        } else {
            order.append(moved)
        }
        Defaults[.launcherCustomOrder] = order
    }

    private func pageLabel(_ page: Int) -> Text {
        page == LauncherPaging.categoriesPage ? Text("Categories") : Text("Apps, page \(page + 1)")
    }

    private func pageDots(pageIDs: Range<Int>) -> some View {
        HStack(spacing: 0) {
            ForEach(pageIDs, id: \.self) { page in
                Button {
                    onPageChanged(page)
                } label: {
                    Group {
                        if page == LauncherPaging.categoriesPage {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 11, weight: .semibold))
                        } else {
                            Capsule()
                                .frame(width: page == currentPage ? 16 : 7, height: 7)
                        }
                    }
                    .foregroundStyle(page == currentPage ? Color.primary.opacity(0.85) : Color.primary.opacity(0.35))
                    .frame(minWidth: 20, minHeight: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pageLabel(page))
                .accessibilityAddTraits(page == currentPage ? .isSelected : [])
                .help(pageLabel(page))
                .launcherWidgetPageDrop(profileID: widgetProfileID, page: page) { onPageChanged(page) }
            }
        }
        .padding(.horizontal, 14)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: currentPage)
    }
}

/// One app tile: icon above a wrapped, centred name.
private struct LauncherGridCell: View {
    let app: LauncherApp
    let isSelected: Bool

    @State private var icon: NSImage?
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    AnchorCorners.rectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.15))
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
            AnchorCorners.rectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isSelected ? 0.09 : hovered ? 0.04 : 0))
                .overlay(
                    AnchorCorners.rectangle(cornerRadius: 12)
                        .anchorStrokeBorder(
                            isSelected ? Color.white.opacity(0.16) : .clear, lineWidth: 1)
                )
        )
        .onHover { hovered = $0 }
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


/// A folder in the grid: a tile showing the first four icons inside it.
private struct LauncherFolderCell: View {
    let name: String
    let apps: [LauncherApp]

    /// A computed property rather than a `let` inside the ViewBuilder: a
    /// declaration in there left the element type unresolved and ForEach fell
    /// through to its Binding overload.
    private var previewIcons: [LauncherApp] { Array(apps.prefix(4)) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                AnchorCorners.rectangle(cornerRadius: 14)
                    .fill(Color.primary.opacity(0.10))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 3), count: 2), spacing: 3) {
                    ForEach(previewIcons) { app in
                        LauncherAppIcon(app: app, size: 18)
                    }
                }
            }
            .frame(width: 52, height: 52)

            Text(name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .help("\(apps.count) apps")
    }
}


/// One app's icon, loaded through the shared cache.
///
/// `LauncherApp` carries no icon of its own — `NSWorkspace.icon(forFile:)` hits
/// disk on every call, so icons are rendered once and cached by path and mtime.
/// This is the small reusable form of what `LauncherGridCell` does, for places
/// that want the icon without the label around it.
private struct LauncherAppIcon: View {
    let app: LauncherApp
    let size: CGFloat

    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(Color.primary.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard icon == nil else { return }
            if let cached = AppIconCache.shared.icon(for: app, completion: { icon = $0 }) {
                icon = cached
            }
        }
    }
}

/// Advances an app drag to an adjacent page after the pointer rests at the edge.
private struct PageDropZone: View {
    let forward: Bool
    let onNavigate: () -> Void

    @State private var isTargeted = false
    @State private var timer: Timer?

    var body: some View {
        Rectangle()
            .fill(isTargeted ? Color.accentColor.opacity(0.2) : .clear)
            .frame(width: 20)
            .overlay {
                if isTargeted {
                    Image(systemName: forward ? "chevron.right" : "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .onDrop(of: [.text], isTargeted: $isTargeted) { _ in false }
            .onChange(of: isTargeted) { _, targeted in
                timer?.invalidate()
                timer = nil
                if targeted {
                    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                        DispatchQueue.main.async { onNavigate() }
                    }
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }
}
