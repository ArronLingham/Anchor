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

/// One ordering for display, keyboard navigation, scrolling and activation.
private enum LauncherSearchEntry: Identifiable {
    case app(LauncherResult)
    case command(LauncherCommand.ScoredCommand)

    var id: String {
        switch self {
        case .app(let result): return "app:" + result.id
        case .command(let result): return "command:" + result.id
        }
    }
    var score: Double {
        switch self {
        case .app(let result): return result.score
        case .command(let result): return Double(result.score)
        }
    }
    var isApp: Bool { if case .app = self { return true }; return false }
    var isSearchOnly: Bool { if case .app(let result) = self { return result.app.isSearchOnly }; return false }
}

/// The launcher: a search field over either a filtered result list (while
/// typing) or a Launchpad-style grid of everything (when the field is empty).
struct LauncherView: View {
    var widgetProfileID: String = "default"
    var screen: NSScreen? = nil
    let onLaunch: (LauncherApp) -> Void
    let onDismiss: () -> Void

    @ObservedObject private var index = AppIndex.shared
    /// Observed so the list refreshes when `shortcuts list` finally answers.
    /// Loading runs a subprocess, so the first search always ran against an
    /// empty `names` — which is why Apple Shortcuts never appeared.
    @ObservedObject private var shortcuts = AppleShortcutsManager.shared

    @State private var query = ""
    @State private var results: [LauncherResult] = []
    @State private var commands: [LauncherCommand.ScoredCommand] = []
    @State private var entries: [LauncherSearchEntry] = []
    @State private var selection = 0
    @State private var calculation: String?
    @State private var copiedFlash = false
    @FocusState private var queryFocused: Bool
    @Default(.launcherShowGridWhenEmpty) private var showGridWhenEmpty
    @Default(.launcherLayoutMode) private var layoutMode
    @Default(.launcherPresentationMode) private var presentationMode
    @Default(.launcherShowCategoryPage) private var showCategoryPage
    @Default(.launcherRecallSeconds) private var recallSeconds
    @Default(.launcherFolders) private var folders
    @Default(.launcherEnableCalculator) private var calculatorEnabled

    @Default(.launcherSortMode) private var sortMode
    @Default(.launcherCustomOrder) private var customOrder

    @State private var gridLayout = LauncherGridLayout.default
    @State private var browsePage = LauncherPaging.landingPage(
        showCategories: Defaults[.launcherShowCategoryPage],
        startOnCategories: Defaults[.launcherStartsOnCategories]
    )
    @State private var searchPage = 0
    @State private var keyboardSelection: Int?
    @State private var selectedCategory: AppCategory?

    private var includesCategories: Bool { showCategoryPage && !gridIsFiltered }

    private var pageIDs: Range<Int> {
        LauncherPaging.pageIDs(appPageCount: LauncherPaging.pageCount(
            folderCount: resolvedFolders.count, appCount: ungroupedApps.count, perPage: gridLayout.perPage
        ), showCategories: includesCategories)
    }

    private var currentPage: Int {
        min(max(pageIDs.lowerBound, gridIsFiltered ? searchPage : browsePage), pageIDs.upperBound - 1)
    }

    private func selections(on page: Int) -> Range<Int> {
        LauncherPaging.selections(onPage: page, folderCount: resolvedFolders.count,
                                  perPage: gridLayout.perPage, appCount: ungroupedApps.count)
    }

    private func showPage(_ page: Int, selecting preferredSelection: Int? = nil, fromKeyboard: Bool = false) {
        guard pageIDs.contains(page) else { return }
        if gridIsFiltered { searchPage = page } else { browsePage = page }
        let visibleSelections = selections(on: page)
        if let preferredSelection, visibleSelections.contains(preferredSelection) {
            selection = preferredSelection
        } else if !visibleSelections.contains(selection), let first = visibleSelections.first {
            selection = first
        }
        keyboardSelection = fromKeyboard && visibleSelections.contains(selection) ? selection : nil
    }

    private static let rowHeight: CGFloat = 50

    /// The last search, and when the launcher was closed on it.
    ///
    /// Static because the view is rebuilt from scratch every time the panel
    /// opens — there is no instance to carry it. Reopening within
    /// `launcherRecallSeconds` puts the text back and selects it, so a second
    /// look at the same search costs nothing and typing still replaces it.
    private static var lastQuery = ""
    private static var lastClosed: Date?

    private func restoreRecalledQuery() {
        guard recallSeconds > 0,
              !Self.lastQuery.isEmpty,
              let closed = Self.lastClosed,
              Date().timeIntervalSince(closed) <= recallSeconds
        else { return }
        query = Self.lastQuery
    }

    private func rememberQuery() {
        Self.lastQuery = query
        Self.lastClosed = Date()
    }


    /// The filtered grid draws search matches without folder tiles.
    private var gridIsFiltered: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Resolve only installed apps and omit folders left with no members.
    private var resolvedFolders: [(name: String, apps: [LauncherApp])] {
        guard !gridIsFiltered, !folders.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: index.openingApps.map { ($0.id, $0) })
        return folders
            .map { (name: $0.key, apps: $0.value.compactMap { byID[$0] }) }
            .filter { !$0.apps.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The apps the grid lays out loose, i.e. everything not filed away.
    ///
    /// Selection indexes THIS list, which is why folders are excluded from it:
    /// the arrow keys and Return keep addressing apps whether or not folders
    /// exist, and folders are opened with the mouse.
    private var ungroupedApps: [LauncherApp] {
        // While searching, show every match. Excluding filed apps here made an
        // app impossible to find by name once it was in a folder — which is a
        // much worse outcome than a folder's contents appearing in results.
        guard !gridIsFiltered, !folders.isEmpty else { return results.map(\.app) }
        let filed = Set(folders.values.flatMap { $0 })
        return results.map(\.app).filter { !filed.contains($0.id) }
    }

    private var showingGrid: Bool {
        // `showGridWhenEmpty` is the old switch and still acts as a master off:
        // with it off there is no grid at all, whichever way round the mode is.
        guard showGridWhenEmpty else { return false }
        return commands.isEmpty && layoutMode.showsGrid(queryIsEmpty: query.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if let calculation {
                calculatorRow(calculation)
            } else if showingGrid {
                grid
            } else if results.isEmpty && commands.isEmpty {
                emptyState
            } else {
                resultList
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: 1160)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, presentationMode == .fullscreen ? 54 : 26)
        .padding(.horizontal, presentationMode == .fullscreen ? 48 : 24)
        .padding(.bottom, presentationMode == .fullscreen ? 24 : 16)
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Launchpad")
            .help("Close Launchpad (Esc)")
            .padding(presentationMode == .fullscreen ? 22 : 12)
        }
        .background {
            LauncherBackdrop(mode: presentationMode, screen: screen, onDismiss: onDismiss)
        }
        .anchorCornerContainer(radius: presentationMode == .fullscreen ? 0 : 26)
        .transaction { if LauncherMotion.reduced { $0.animation = nil; $0.disablesAnimations = true } }
        .defaultFocus($queryFocused, true)
        .onAppear {
            restoreRecalledQuery()
            index.refreshIfNeeded()
            // Start the shortcuts subprocess as the panel opens rather than
            // lazily on the first keystroke, so it has a chance to finish
            // before the user has typed anything worth matching.
            if Defaults[.enableShortcutsLauncher] {
                AppleShortcutsManager.shared.loadIfNeeded()
            }
            recompute()
            queryFocused = true
            DispatchQueue.main.async {
                queryFocused = true
            }
        }
        // Re-assert focus when the panel actually becomes key.
        //
        // The onAppear assignment above runs one runloop turn after the view
        // appears, which is not necessarily after the panel is key — and a
        // @FocusState set on a non-key window is dropped silently. Gating on
        // the notification makes the assignment land at the moment it can
        // take effect. Filtered to the launcher's own panel so a notch window
        // becoming key never pulls focus into the search field.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard note.object is LauncherPanel else { return }
            queryFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            queryFocused = true
        }
        .onDisappear { rememberQuery() }
        .onChange(of: query) { _, _ in
            closeCategory()
            searchPage = 0
            recompute()
        }
        .onChange(of: showCategoryPage) { _, enabled in
            if !enabled {
                closeCategory()
                if browsePage == LauncherPaging.categoriesPage { browsePage = 0 }
            }
            if showingGrid { showPage(currentPage) }
        }
        .onChange(of: showGridWhenEmpty) { _, _ in recompute() }
        .onChange(of: layoutMode) { _, _ in recompute() }
        .onChange(of: folders) { _, _ in recompute(resetSelection: false) }
        .onChange(of: sortMode) { _, _ in recompute(resetSelection: false) }
        .onChange(of: customOrder) { _, _ in recompute(resetSelection: false) }
        .onChange(of: index.apps) { _, _ in recompute(resetSelection: false) }
        // `loadIfNeeded()` returns before the subprocess does. Without this the
        // results were computed once against an empty list and never revisited,
        // so the shortcuts existed, parsed correctly, and were simply never
        // shown.
        .onChange(of: shortcuts.names) { _, _ in recompute(resetSelection: false) }
        .anchorTheme()
    }

    // MARK: - Pieces

    private var grid: some View {
        LauncherGridView(
            apps: ungroupedApps,
            folders: resolvedFolders,
            allowsReorder: !gridIsFiltered,
            selection: $selection,
            currentPage: currentPage,
            keyboardSelection: keyboardSelection,
            includesCategories: includesCategories,
            widgetProfileID: widgetProfileID,
            onPageChanged: { showPage($0) },
            onLayoutChanged: { layout in
                gridLayout = layout
                showPage(currentPage)
            },
            onOpenCategory: { category in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selectedCategory = category
                }
            },
            onLaunch: onLaunch
        )
        .id(gridIsFiltered)
        .overlay {
            if let selectedCategory, includesCategories {
                LauncherCategoryDetailView(
                    category: selectedCategory,
                    apps: index.apps(in: selectedCategory),
                    onClose: closeCategory,
                    onLaunch: onLaunch
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: calculation == nil ? "magnifyingglass" : "equal.square")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search applications", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .regular))
                .focused($queryFocused)
                .onSubmit(activateSelection)
                .onKeyPress(.upArrow) { move(by: -stride); return .handled }
                .onKeyPress(.downArrow) { move(by: stride); return .handled }
                .onKeyPress(.leftArrow) {
                    guard showingGrid else { return .ignored }
                    move(by: -1, horizontally: true)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard showingGrid else { return .ignored }
                    move(by: 1, horizontally: true)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if selectedCategory != nil { closeCategory() } else { onDismiss() }
                    return .handled
                }

            // The copy confirmation lives in the calculator row itself, which is
            // where the user is looking when they press ↩.
            if index.isIndexing {
                ProgressView().controlSize(.small)
            }
            if !query.isEmpty {
                Button { query = ""; queryFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .frame(maxWidth: 560)
        .frame(height: 48)
        .padding(.horizontal, 16)
        .background(AnchorSurface(depth: .inset, radius: 14))
        .anchorCornerContainer(radius: 14)
        .overlay {
            AnchorCorners.rectangle(cornerRadius: 14)
                .anchorStrokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .padding(.bottom, 24)
        .contentShape(Rectangle())
        .onTapGesture {
            queryFocused = true
        }
    }

    private func closeCategory() {
        guard selectedCategory != nil else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { selectedCategory = nil }
        queryFocused = true
    }

    /// In the grid, ↑/↓ move a whole row; in the list they move one item.
    private var stride: Int { showingGrid ? gridLayout.columns : 1 }

    private func calculatorRow(_ value: String) -> some View {
        VStack(spacing: 10) {
            // Echo the expression above the answer so a mistyped operand is
            // obvious without looking back up at the field.
            Text(query.trimmingCharacters(in: .whitespaces))
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 52, weight: .light, design: .rounded))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.15), value: value)

            Label(copiedFlash ? "Copied" : "Press ↩ to copy", systemImage: copiedFlash ? "checkmark" : "return")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                        Group {
                            switch entry {
                            case .command(let scored):
                                LauncherCommandRow(scored: scored, isSelected: position == selection)
                            case .app(let result):
                                LauncherRow(result: result, isSelected: position == selection)
                            }
                        }
                        .frame(height: Self.rowHeight)
                        .id(entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = position
                            activateSelection()
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .onChange(of: selection) { _, new in
                let targetId = entries.indices.contains(new) ? entries[new].id : nil
                if let targetId {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(targetId, anchor: .center) }
                }
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

    /// - Parameter resetSelection: true when the user changed the query, false
    ///   when the index refreshed underneath a stable query. Editing the query
    ///   must always drop the cursor back to the best match — carrying it over
    ///   meant typing a letter while sitting on grid tile 50 selected the *last*
    ///   of three matches instead of the first.
    private func recompute(resetSelection: Bool = true) {
        calculation = calculatorEnabled ? CalculatorAction.evaluate(query) : nil
        commands = LauncherCommand.search(query)
        // The grid shows everything; the filtered list is capped for speed.
        results = index.search(query, limit: showingGrid ? Int.max : 40)
        entries = (results.map(LauncherSearchEntry.app) + commands.map(LauncherSearchEntry.command)).sorted {
            LauncherSearch.precedes(score: $0.score, isApp: $0.isApp, id: $0.id, lhsSearchOnly: $0.isSearchOnly,
                                    score: $1.score, isApp: $1.isApp, id: $1.id, rhsSearchOnly: $1.isSearchOnly)
        }

        if resetSelection { selection = 0 }
        if showingGrid {
            showPage(currentPage)
        } else {
            selection = min(selection, max(0, entries.count - 1))
        }
    }

    private func move(by delta: Int, horizontally: Bool = false) {
        guard calculation == nil, selectedCategory == nil else { return }
        guard showingGrid else {
            guard !entries.isEmpty else { return }
            selection = (selection + delta + entries.count) % entries.count
            return
        }

        let page = currentPage
        let visibleSelections = selections(on: page)
        guard visibleSelections.contains(selection) else {
            if horizontally { showPage(page + delta, fromKeyboard: true) }
            return
        }

        let next = selection + delta
        if horizontally, next < 0, page > pageIDs.lowerBound {
            showPage(page - 1, fromKeyboard: true)
            return
        }

        let appSelection = min(max(0, next), ungroupedApps.count - 1)
        let appPage = LauncherPaging.page(
            forSelection: appSelection, folderCount: resolvedFolders.count, perPage: gridLayout.perPage
        )
        showPage(appPage, selecting: appSelection, fromKeyboard: true)
    }

    private func activateSelection() {
        guard selectedCategory == nil else { return }
        if let calculation {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(calculation, forType: .string)
            withAnimation { copiedFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation { copiedFlash = false }
            }
            return
        }
        if showingGrid {
            guard selections(on: currentPage).contains(selection) else { return }
            onLaunch(ungroupedApps[selection])
            return
        }
        guard entries.indices.contains(selection) else { return }
        switch entries[selection] {
        case .app(let result): onLaunch(result.app)
        case .command(let result):
            onDismiss()
            result.command.run()
        }
    }
}

/// One result row: icon, name with matched characters emphasised, path hint.
private struct LauncherRow: View {
    let result: LauncherResult
    let isSelected: Bool

    @Default(.launcherShowPaths) private var showPaths
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    AnchorCorners.rectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                highlightedName
                    .font(.system(size: 14))
                    .lineLimit(1)
                if showPaths {
                    Text(locationHint)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
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
            AnchorCorners.rectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
                .padding(.horizontal, 10)
        )
        .onAppear(perform: loadIcon)
    }

    /// Bolds the characters the query actually matched.
    ///
    /// Built as one `AttributedString` rather than concatenated `Text` values:
    /// `Text` + `Text` is deprecated as of macOS 26, and a single attributed
    /// string also lets the layout engine kern and truncate the name as a whole
    /// instead of as N independent runs.
    private var highlightedName: Text {
        let matched = Set(result.matchedIndices)
        guard !matched.isEmpty else { return Text(result.app.name) }

        var attributed = AttributedString(result.app.name)
        attributed.foregroundColor = .secondary

        let characters = attributed.characters
        let count = characters.count
        for offset in matched.sorted() where offset >= 0 && offset < count {
            let start = characters.index(characters.startIndex, offsetBy: offset)
            let end = characters.index(after: start)
            attributed[start..<end].foregroundColor = .primary
            attributed[start..<end].inlinePresentationIntent = .stronglyEmphasized
        }

        return Text(attributed)
    }

    /// A short, readable home for the app rather than a full absolute path.
    /// Nearly every result lives in one of four places, and printing
    /// `/System/Cryptexes/App/System/Applications` under Safari is noise.
    private var locationHint: String {
        let path = result.app.url.deletingLastPathComponent().path

        if path.hasPrefix(NSHomeDirectory()) { return "User" }
        if path.hasPrefix("/System/Cryptexes") { return "System" }
        if path.hasPrefix("/System") { return "System" }
        if path == "/Applications" { return "Applications" }
        if path.hasPrefix("/Applications") {
            // /Applications/Adobe -> "Applications › Adobe"
            return "Applications › " + (path as NSString).lastPathComponent
        }
        return (path as NSString).lastPathComponent
    }

    private func loadIcon() {
        guard icon == nil else { return }
        if let cached = AppIconCache.shared.icon(for: result.app, completion: { icon = $0 }) {
            icon = cached
        }
    }
}

/// A command result — same shape as an app row so the list reads uniformly.
private struct LauncherCommandRow: View {
    let scored: LauncherCommand.ScoredCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: scored.command.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                highlightedTitle
                    .font(.system(size: 14))
                    .lineLimit(1)
                Text(scored.command.subtitle)
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
            AnchorCorners.rectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
                .padding(.horizontal, 10)
        )
    }

    private var highlightedTitle: Text {
        let matched = Set(scored.matchedIndices)
        guard !matched.isEmpty else { return Text(scored.command.title) }
        var composed = Text("")
        for (offset, character) in scored.command.title.enumerated() {
            let piece = Text(String(character))
            composed = composed
                + (matched.contains(offset)
                    ? piece.fontWeight(.bold).foregroundColor(.primary)
                    : piece.foregroundColor(.secondary))
        }
        return composed
    }
}
