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
    /// Folder name -> its apps, resolved by the caller. Drawn before the loose
    /// apps, and deliberately NOT part of `selection`: folders are opened with
    /// the mouse, while the arrow keys and Return continue to address apps, so
    /// keyboard navigation means the same thing whether or not folders exist.
    var folders: [(name: String, apps: [LauncherApp])] = []
    @Binding var selection: Int
    @Default(.launcherNavigationStyle) private var navigationStyle
    @Default(.launcherSortMode) private var sortMode
    @State private var draggingID: String?
    @State private var openFolder: String?
    @State private var renaming: String = ""
    let onLaunch: (LauncherApp) -> Void

    static var columns: Int { max(3, min(12, Defaults[.launcherGridColumns])) }
    static var rows: Int { max(2, min(8, Defaults[.launcherGridRows])) }
    static var perPage: Int { columns * rows }

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

    private var pages: [[Slot]] {
        let all = slots
        guard Self.perPage > 0, !all.isEmpty else { return [] }
        return stride(from: 0, to: all.count, by: Self.perPage).map {
            Array(all[$0..<min($0 + Self.perPage, all.count)])
        }
    }

    private var currentPage: Int {
        guard Self.perPage > 0 else { return 0 }
        // Selection addresses apps; folders occupy slots ahead of them, so the
        // page has to be computed from the slot position, not the app index.
        return (selection + folders.count) / Self.perPage
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
        .overlay { folderOverlay }
    }

    @ViewBuilder
    private var folderOverlay: some View {
        if let name = openFolder,
           let members = folders.first(where: { $0.name == name })?.apps {
            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.35))
                    .ignoresSafeArea()
                    .onTapGesture { openFolder = nil }

                VStack(spacing: 12) {
                    TextField("Folder name", text: $renaming)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                        .onSubmit { renameFolder(from: name, to: renaming) }

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(5, max(1, members.count))),
                        spacing: 10
                    ) {
                        ForEach(members) { app in
                            LauncherGridCell(app: app, isSelected: false)
                                .contentShape(Rectangle())
                                .onTapGesture { onLaunch(app) }
                                .contextMenu {
                                    Button("Move out of folder") {
                                        removeFromFolder(app.id, folder: name)
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: 520)

                    Text("Drag an app onto a folder to file it. ⌥-drag one app onto another to make a new folder.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(radius: 24, y: 8)
                .frame(maxWidth: 600)
            }
            .transition(.opacity)
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

    private func page_(_ page: [Slot], pageIndex: Int) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 4), count: Self.columns),
            spacing: 4
        ) {
            ForEach(page) { slot in
                switch slot {
                case .folder(let name, let members):
                    LauncherFolderCell(name: name, apps: members)
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
                        enabled: sortMode.isReorderable,
                        appID: app.id,
                        draggingID: $draggingID,
                        onDrop: { moved in dropped(moved, onto: app.id) }))
                }
            }
        }
        .padding(.horizontal, 20)
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
                RoundedRectangle(cornerRadius: 14)
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
