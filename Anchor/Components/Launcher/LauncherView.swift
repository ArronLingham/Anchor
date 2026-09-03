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

/// The launcher: a search field over either a filtered result list (while
/// typing) or a Launchpad-style grid of everything (when the field is empty).
struct LauncherView: View {
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
    @State private var selection = 0
    @State private var calculation: String?
    @State private var copiedFlash = false
    @FocusState private var queryFocused: Bool
    @Default(.launcherShowGridWhenEmpty) private var showGridWhenEmpty
    @Default(.launcherLayoutMode) private var layoutMode
    @Default(.launcherFullScreen) private var fullScreen
    @Default(.launcherRecallSeconds) private var recallSeconds
    @Default(.launcherFolders) private var folders
    @Default(.launcherEnableCalculator) private var calculatorEnabled

    private static let rowHeight: CGFloat = 44

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


    /// Folders, resolved from stored ids to the apps that still exist.
    ///
    /// An id for an app that has since been uninstalled is dropped rather than
    /// leaving a gap, and a folder left with nothing in it is not shown at all
    /// — a tile you cannot open is worse than no tile.
    private var resolvedFolders: [(name: String, apps: [LauncherApp])] {
        let byID = Dictionary(uniqueKeysWithValues: index.apps.map { ($0.id, $0) })
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
        let filed = Set(folders.values.flatMap { $0 })
        return results.map(\.app).filter { !filed.contains($0.id) }
    }

    private var showingGrid: Bool {
        // `showGridWhenEmpty` is the old switch and still acts as a master off:
        // with it off there is no grid at all, whichever way round the mode is.
        guard showGridWhenEmpty else { return false }
        return layoutMode.showsGrid(queryIsEmpty: query.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            LauncherWidgetStrip()
            Divider().opacity(0.5)

            if let calculation {
                calculatorRow(calculation)
            } else if showingGrid {
                LauncherGridView(
                    apps: ungroupedApps,
                    folders: resolvedFolders,
                    selection: $selection,
                    onLaunch: onLaunch
                )
            } else if results.isEmpty && commands.isEmpty {
                emptyState
            } else {
                resultList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 100)
        .padding(.horizontal, 100)
        // The blurred backdrop.
        //
        // The panel is already the size of the screen and sits above everything
        // including full-screen apps; without this it was transparent, so the
        // launcher read as a floating box rather than taking over the screen.
        // Clicking the backdrop dismisses, which is the behaviour anyone
        // expects from a full-screen overlay.
        .background {
            if fullScreen {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(Color.black.opacity(0.28))
                }
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
            }
        }
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
        .onDisappear { rememberQuery() }
        .onChange(of: query) { _, _ in recompute() }
        .onChange(of: index.apps) { _, _ in recompute(resetSelection: false) }
        // `loadIfNeeded()` returns before the subprocess does. Without this the
        // results were computed once against an empty list and never revisited,
        // so the shortcuts existed, parsed correctly, and were simply never
        // shown.
        .onChange(of: shortcuts.names) { _, _ in recompute(resetSelection: false) }
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

            // The copy confirmation lives in the calculator row itself, which is
            // where the user is looking when they press ↩.
            if index.isIndexing {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: 680)
        .frame(height: 62)
        .padding(.horizontal, 24)
    }

    /// In the grid, ↑/↓ move a whole row; in the list they move one item.
    private var stride: Int { showingGrid ? Defaults[.launcherGridColumns] : 1 }

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
                    ForEach(Array(commands.enumerated()), id: \.element.id) { position, scored in
                        LauncherCommandRow(scored: scored, isSelected: position == selection)
                            .frame(height: Self.rowHeight)
                            .id(scored.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = position
                                activateSelection()
                            }
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { offset, result in
                        let position = offset + commands.count
                        LauncherRow(result: result, isSelected: position == selection)
                            .frame(height: Self.rowHeight)
                            .id(result.id)
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
                let targetId: AnyHashable?
                if new < commands.count {
                    targetId = commands[new].id
                } else {
                    let idx = new - commands.count
                    if idx >= 0 && idx < results.count {
                        targetId = results[idx].id
                    } else {
                        targetId = nil
                    }
                }
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
        commands = showingGrid ? [] : LauncherCommand.search(query)
        // The grid shows everything; the filtered list is capped for speed.
        results = index.search(query, limit: showingGrid ? Int.max : 40)

        if resetSelection || selectableCount == 0 {
            selection = 0
        } else {
            selection = min(selection, selectableCount - 1)
        }
    }

    /// How many things the arrow keys can address.
    ///
    /// In grid mode this MUST be the list the grid actually draws. The grid
    /// lays out `ungroupedApps`, and its cells compare `index == selection`
    /// against indices into that filtered array — so counting `results` here,
    /// which still contains everything filed inside folders, makes the two
    /// disagree the moment one folder exists: ↓ walks the selection past the
    /// last drawn cell (no cursor anywhere) and Return launches an app that is
    /// in a folder and not on screen.
    private var selectableCount: Int {
        showingGrid ? ungroupedApps.count : commands.count + results.count
    }

    private func move(by delta: Int) {
        guard calculation == nil, selectableCount > 0 else { return }
        let next = selection + delta
        // Clamp in the grid so ↓ on the last row does not wrap to the start;
        // wrap in the list, where it reads as a loop through a short set.
        if showingGrid {
            selection = max(0, min(selectableCount - 1, next))
        } else {
            selection = (next + selectableCount) % selectableCount
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
        if commands.indices.contains(selection) {
            let command = commands[selection].command
            onDismiss()
            command.run()
            return
        }
        // Same index space as `selectableCount` — the grid addresses the apps
        // it draws, which excludes anything filed in a folder.
        if showingGrid {
            guard ungroupedApps.indices.contains(selection) else { return }
            onLaunch(ungroupedApps[selection])
            return
        }
        let appIndex = selection - commands.count
        guard results.indices.contains(appIndex) else { return }
        onLaunch(results[appIndex].app)
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
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
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
            RoundedRectangle(cornerRadius: 8)
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
            RoundedRectangle(cornerRadius: 8)
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
