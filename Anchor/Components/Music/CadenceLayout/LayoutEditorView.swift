/*
 * Cadence
 * Copyright (C) 2026 Cadence Contributors
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

/// Arrange a surface by dragging its elements around.
///
/// The preview is the **real** `PlayerSurfaceView` — real glass, real album
/// tint, a really spinning record — with a grid and a drag layer over the top.
/// Anchor's `MusicSlotConfigurationView` draws grey rounded rects instead,
/// which cannot show you any of that, so you arrange blind and check on the
/// real thing.
///
/// It is bound to `PlayerSnapshot.sample` rather than to what is playing: a
/// layout that shifts under the cursor when a track changes is miserable to
/// work with, and the sample's deliberately long title shows you truncation
/// without waiting for a song that has one.
struct LayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Default(.playerLayouts) private var layouts
    @Default(.sliderColor) private var sliderColour
    @Default(.visualizerBarCount) private var visualizerBars
    @Default(.coloredSpectrogram) private var colouredBars
    @Default(.accentColor) private var accentColour
    @State private var surface: PlayerSurface = .desktop
    /// The element the inspector edits. Always a member of `selectedIDs` when
    /// anything is selected.
    @State private var selection: UUID?
    /// Everything highlighted. Inspector edits, nudges and delete apply to all
    /// of it, so ⌘-click lets you set the priority of six buttons at once
    /// rather than six times.
    @State private var selectedIDs: Set<UUID> = []
    @State private var dragging: UUID?
    @State private var hoverPreview = false
    @StateObject private var history = LayoutHistory()
    @FocusState private var editorFocused: Bool

    private var layout: SurfaceLayout {
        get { layouts[surface] }
        nonmutating set { layouts[surface] = newValue }
    }

    /// The single door every edit goes through.
    ///
    /// Undo is only trustworthy if nothing can change a layout without
    /// recording the prior state, so there is exactly one mutating path and the
    /// setter above is used only by it and by undo/redo themselves.
    private func edit(_ transform: (inout SurfaceLayout) -> Void) {
        let before = layout
        var updated = before
        transform(&updated)
        guard updated != before else { return }
        history.record(before, for: surface)
        layout = normalisingRows(updated)
    }

    var body: some View {
        VStack(spacing: 0) {
            surfacePicker
            Divider()
            HSplitView {
                VStack(spacing: 10) {
                    preview
                    palette
                }
                .padding(14)
                .frame(minWidth: 420)

                inspector
                    .frame(width: 260)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 940, minHeight: 600)
        .focusable()
        .focusEffectDisabled()
        .focused($editorFocused)
        // Focus has to be taken back deliberately. `.focusable()` alone was not
        // enough: Cmd+Z worked on a freshly opened window and then stopped the
        // moment anything in the preview was clicked, because the click moved
        // focus off the root and `onKeyPress` only fires for the focused view.
        // Selecting an element is exactly when the arrow keys become useful, so
        // that is the moment to re-claim it.
        .onAppear { editorFocused = true }
        .onChange(of: selection) { _, _ in editorFocused = true }
        .onChange(of: surface) { _, _ in editorFocused = true }
        // Arrow keys nudge by one cell. A drag is the fast way to get roughly
        // right; this is the only way to get exactly right, because a synthetic
        // pointer cannot reliably hit a 42pt cell and neither can a hand.
        .onKeyPress(.leftArrow) { nudge(dx: -1, dy: 0) }
        .onKeyPress(.rightArrow) { nudge(dx: 1, dy: 0) }
        .onKeyPress(.upArrow) { nudge(dx: 0, dy: -1) }
        .onKeyPress(.downArrow) { nudge(dx: 0, dy: 1) }
        // Backspace and forward-delete both, matched on the character rather
        // than on `KeyEquivalent.delete` — that constant did not match what the
        // Backspace key actually sends, so the shortcut silently did nothing
        // while every other key in this block worked.
        .onKeyPress(phases: .down) { press in
            let deleteKeys: Set<Character> = ["\u{8}", "\u{7F}", "\u{F728}"]
            guard press.characters.contains(where: { deleteKeys.contains($0) })
            else { return .ignored }
            return deleteSelection()
        }
        .onKeyPress(.escape) {
            selection = nil
            selectedIDs = []
            return .handled
        }
        // Both cases. With Shift held the reported character is "Z", so a set
        // containing only "z" matched Cmd+Z and silently ignored Shift+Cmd+Z —
        // undo worked and redo did nothing, which is exactly the sort of
        // half-working that reads as "redo is broken" rather than as a typo.
        .onKeyPress(keys: ["z", "Z"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            let restored =
                press.modifiers.contains(.shift)
                ? history.redo(surface, current: layout)
                : history.undo(surface, current: layout)
            guard let restored else { return .handled }
            layout = restored
            if !layout.placements.contains(where: { $0.id == selection }) { selection = nil }
            return .handled
        }
    }

    // MARK: Keyboard

    private func nudge(dx: Int, dy: Int) -> KeyPress.Result {
        guard let id = selection,
            let index = layout.placements.firstIndex(where: { $0.id == id })
        else { return .ignored }
        var moved = layout.placements[index]
        moved.col = max(0, min(moved.col + dx, layout.geometry.columns - moved.colSpan))
        moved.row = max(0, moved.row + dy)
        guard moved != layout.placements[index],
            GridSolver.canPlace(moved, in: layout, ignoring: id)
        else { return .handled }
        edit { $0.placements[index] = moved }
        return .handled
    }

    private func deleteSelection() -> KeyPress.Result {
        guard selection != nil || !selectedIDs.isEmpty else { return .ignored }
        removeSelected()
        return .handled
    }

    private func remove(_ id: UUID) {
        edit { $0.placements.removeAll { $0.id == id } }
        selection = nil
        selectedIDs = []
    }

    /// One undo step for the whole selection, not one per element.
    private func removeSelected() {
        let doomed = selectedIDs.isEmpty ? Set([selection].compactMap { $0 }) : selectedIDs
        guard !doomed.isEmpty else { return }
        edit { $0.placements.removeAll { doomed.contains($0.id) } }
        selection = nil
        selectedIDs = []
    }

    // MARK: Surface picker

    private func compactSurfaceName(_ surface: PlayerSurface) -> String {
        switch surface {
        case .desktop: return "Desktop"
        case .lockWidget: return "Lock widget"
        case .lockFull: return "Lock full screen"
        case .desktopFull: return "Desktop full screen"
        case .launcher: return "Launcher"
        }
    }

    private var surfacePicker: some View {
        HStack {
            Picker("", selection: $surface) {
                ForEach(PlayerSurface.allCases, id: \.self) { option in
                    Text(compactSurfaceName(option))
                        .tag(option)
                        .help(option.displayName)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: surface) { _, _ in selection = nil }
            .help("Each surface keeps its own layout and its own undo history.")

            Spacer()

            // `fixedSize` and a short label on purpose. "Show hover elements"
            // wrapped to three lines once undo and redo joined this row, which
            // made the toolbar taller and pushed the preview down — a cosmetic
            // problem that also moves every element under the pointer.
            Toggle(isOn: $hoverPreview) {
                Image(systemName: "hand.point.up.left")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Preview what appears when the pointer is over this surface.")

            // Always here, not only when the inspector is empty. It used to sit
            // in the no-selection placeholder, and nothing could clear a
            // selection — so one click on an element put Reset permanently out
            // of reach.
            Button {
                if let restored = history.undo(surface, current: layout) {
                    layout = restored
                    if !layout.placements.contains(where: { $0.id == selection }) { selection = nil }
                }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!history.canUndo(surface))
            .help("Undo (⌘Z)")

            Button {
                if let restored = history.redo(surface, current: layout) {
                    layout = restored
                    if !layout.placements.contains(where: { $0.id == selection }) { selection = nil }
                }
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!history.canRedo(surface))
            .help("Redo (⇧⌘Z)")

            Menu {
                ForEach(LayoutPreset.all(for: surface), id: \.id) { preset in
                    Button(preset.name) {
                        // A normal edit, so ⌘Z takes it back — applying a
                        // preset should never be the one action you cannot undo.
                        edit { $0 = preset.layout }
                        selection = nil
                        selectedIDs = []
                        if surface == .desktop { Defaults[.playerHeightBudget] = 0 }
                    }
                    .help(preset.detail)
                }
            } label: {
                Label("Presets", systemImage: "square.grid.2x2")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Replace this surface with a ready-made arrangement. Undoable.")

            Button("Reset") {
                // Reset is recorded too, so it is undoable. Losing an arranged
                // surface to a mis-click on Reset would be worse than the
                // mis-drop undo exists for.
                history.record(layout, for: surface)
                layout = PlayerLayouts.defaults[surface]
                selection = nil
                selectedIDs = []
                // The height budget is part of "how this surface currently
                // looks" even though it is not part of the layout. Resetting
                // without clearing it restored every placement and then let the
                // solver drop the bottom ones straight back out again, so Reset
                // looked like it had not worked — the reported "reset doesn't
                // fix the things missing at the bottom".
                if surface == .desktop { Defaults[.playerHeightBudget] = 0 }
            }
            .help("Restore this surface to the layout Cadence ships with.")
        }
        .padding(12)
        .frame(height: 52)
    }

    // MARK: Preview

    /// A representative size per surface, so the preview is proportioned like
    /// the real thing rather than like the settings window.
    private var previewSize: CGSize {
        switch surface {
        case .desktop: return CGSize(width: 320, height: 0)
        case .lockWidget: return CGSize(width: 380, height: 0)
        case .lockFull, .desktopFull: return CGSize(width: 640, height: 400)
        case .launcher: return CGSize(width: 220, height: 0)
        }
    }

    /// The name the drag gesture reports coordinates in.
    ///
    /// `coordinateSpace: .local` was wrong and looked almost right: `.local` on
    /// a drag attached to the *handle* is the handle's own bounds, so dropping
    /// in the middle of a 40pt button reported (20, 20) and every drag landed
    /// near the origin — about one cell short, which reads as an off-by-one
    /// rather than as the wrong coordinate system.
    private static let surfaceSpace = "cadence.surface"

    /// Every placement, laid out as if all of them were visible.
    private var hitTestLayout: GridSolver.ResolvedLayout {
        let size = previewSize
        return GridSolver.solve(
            layout: layout,
            available: CGSize(width: size.width, height: CGFloat.infinity),
            hovering: true)
    }

    private var resolvedPreview: GridSolver.ResolvedLayout {
        let size = previewSize
        let height =
            size.height > 0
            ? size.height
            : GridSolver.intrinsicHeight(
                layout: layout, width: size.width, hovering: hoverPreview)
        return GridSolver.solve(
            layout: layout, available: CGSize(width: size.width, height: height),
            hovering: hoverPreview)
    }

    private var preview: some View {
        let size = previewSize
        let height =
            size.height > 0
            ? size.height
            : GridSolver.intrinsicHeight(
                layout: layout, width: size.width, hovering: hoverPreview)
        let resolved = resolvedPreview

        return ZStack(alignment: .topLeading) {
            backdrop
                .contentShape(Rectangle())
                .onTapGesture { selection = nil }
            PlayerSurfaceView(
                layout: layout,
                style: .forSurface(
                    surface, albumColor: PlayerSnapshot.sample.avgColor,
                    tinted: surface == .desktop, scale: layout.geometry.contentScale,
                    sliderColor: sliderColour, accentColor: accentColour),
                hovering: hoverPreview,
                snapshot: .sample
            )
            .allowsHitTesting(false)

            gridOverlay(width: size.width, height: height, resolved: resolved)
            // Hit-testing uses a solve of EVERY placement, not the one that was
            // drawn. Two reasons: the drawn solve compacts and renumbers rows
            // over only the *visible* set, so writing its row index back into
            // storage silently moves elements when anything is hover-only; and
            // a hover-only element you cannot see is one you cannot drag.
            dragLayer(resolved: hitTestLayout, width: size.width)
        }
        .coordinateSpace(name: Self.surfaceSpace)
        .frame(width: size.width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.18), value: hoverPreview)
    }

    @ViewBuilder private var backdrop: some View {
        switch surface {
        case .desktop:
            Color(nsColor: SurfaceStyle.muted(PlayerSnapshot.sample.avgColor))
        case .lockWidget, .lockFull, .desktopFull:
            LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.08)],
                startPoint: .top, endPoint: .bottom)
        case .launcher:
            Color(white: 0.14)
        }
    }

    /// The cells, drawn only while something is being dragged. A permanent grid
    /// over a live preview makes it impossible to judge the layout.
    @ViewBuilder private func gridOverlay(
        width: CGFloat, height: CGFloat, resolved: GridSolver.ResolvedLayout
    ) -> some View {
        if dragging != nil {
            let geometry = layout.geometry
            let cell = GridSolver.cellWidth(for: geometry, totalWidth: width)
            Canvas { context, _ in
                var y = geometry.padding
                for rowHeight in resolved.rowHeights + [24] {
                    for column in 0..<geometry.columns {
                        let x = geometry.padding + CGFloat(column) * (cell + geometry.gutter)
                        context.stroke(
                            Path(
                                roundedRect: CGRect(x: x, y: y, width: cell, height: rowHeight),
                                cornerRadius: 3),
                            with: .color(.white.opacity(0.22)), lineWidth: 1)
                    }
                    y += rowHeight + geometry.gutter
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// One transparent handle per placement, sitting exactly where the renderer
    /// drew it.
    ///
    /// The handles come from the same `ResolvedLayout` the surface was drawn
    /// from, so what you grab is always what you see — hit-testing against a
    /// second, independently computed layout is how a drag ends up one row off.
    private func dragLayer(
        resolved: GridSolver.ResolvedLayout, width: CGFloat
    ) -> some View {
        ForEach(resolved.elements, id: \.placement.id) { element in
            let isSelected = selectedIDs.contains(element.placement.id)
            let isHidden = element.placement.visibility == .onHover && !hoverPreview
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    Color.accentColor.opacity(
                        isSelected ? 0.28 : (isHidden ? 0.10 : 0.001)))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            Color.accentColor.opacity(
                                isSelected ? 0.9 : (isHidden ? 0.45 : 0)),
                            style: StrokeStyle(
                                lineWidth: 1.5, dash: isHidden && !isSelected ? [3, 3] : []))
                )
                // A hover-only element draws NOTHING when the hover preview is
                // off, so its dashed box was an empty rectangle and the only
                // way to find out what was in it was to toggle the preview and
                // watch the whole surface move. Naming it in place means you
                // can read the arrangement without disturbing it.
                .overlay(
                    Group {
                        if isHidden {
                            VStack(spacing: 2) {
                                Image(systemName: element.placement.element.paletteSymbol)
                                    .font(.system(size: 10))
                                Text(element.placement.element.paletteLabel)
                                    .font(.system(size: 8))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color.accentColor.opacity(0.75))
                            .padding(2)
                        }
                    }
                )
                .frame(width: element.frame.width, height: element.frame.height)
                .offset(x: element.frame.minX, y: element.frame.minY)
                .onTapGesture {
                    // Modifiers read from NSEvent rather than a
                    // `TapGesture().modifiers(.command)`, which competes with
                    // the plain tap and makes plain clicks unreliable.
                    if NSEvent.modifierFlags.contains(.command) {
                        let id = element.placement.id
                        if selectedIDs.contains(id) {
                            selectedIDs.remove(id)
                            if selection == id { selection = selectedIDs.first }
                        } else {
                            selectedIDs.insert(id)
                            selection = id
                        }
                    } else {
                        selection = element.placement.id
                        selectedIDs = [element.placement.id]
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.surfaceSpace))
                        .onChanged { _ in
                            if !selectedIDs.contains(element.placement.id) {
                                selection = element.placement.id
                                selectedIDs = [element.placement.id]
                            }
                            dragging = element.placement.id
                        }
                        .onEnded { value in
                            move(
                                element.placement.id, to: value.location,
                                resolved: resolved, width: width)
                            dragging = nil
                        }
                )
        }
    }

    /// Drop a placement wherever the pointer ended up.
    ///
    /// A move that lands on an occupied cell is **refused**, not squeezed in —
    /// the grid's one invariant is that two base placements never share a cell,
    /// and honouring it here means the user gets a no-op rather than a layout
    /// the solver will silently repair behind them.
    private func move(
        _ id: UUID, to point: CGPoint, resolved: GridSolver.ResolvedLayout, width: CGFloat
    ) {
        guard
            let target = GridSolver.dropTarget(
                at: point, geometry: layout.geometry, totalWidth: width,
                rowHeights: resolved.rowHeights),
            let index = layout.placements.firstIndex(where: { $0.id == id })
        else { return }

        // Dropping in the seam between two rows OPENS a row there. Everything
        // at or below the seam shifts down first, so the moved element lands in
        // genuinely empty space and can never be refused for overlapping.
        if case let .seam(col, before) = target {
            var updated = layout
            for i in updated.placements.indices where updated.placements[i].row >= before {
                updated.placements[i].row += 1
            }
            guard let movedIndex = updated.placements.firstIndex(where: { $0.id == id })
            else { return }
            var inserted = updated.placements[movedIndex]
            // It shifted with everything else; put it in the new empty row.
            inserted.row = before
            inserted.col = max(0, min(col, layout.geometry.columns - inserted.colSpan))
            // An overlay in a row of its own has no base to sit on and the
            // solver would drop it as an orphan, so a seam drop is a base-only
            // gesture. Refusing leaves it where it was, visibly.
            guard inserted.layer == .base else { return }
            updated.placements[movedIndex] = inserted
            edit { $0 = updated }
            return
        }

        guard case let .cell(cellCol, cellRow) = target else { return }
        let cell = (col: cellCol, row: cellRow)

        var moved = layout.placements[index]
        // `resolved` here is the full-set solve, whose rows are the stored rows
        // renumbered contiguously — and `normalisingRows` keeps storage in that
        // shape after every edit, so the two agree and `cell.row` is usable
        // directly. Against the *drawn* solve it would not be.
        moved.col = max(0, min(cell.col, layout.geometry.columns - moved.colSpan))
        moved.row = max(0, cell.row)
        guard GridSolver.canPlace(moved, in: layout, ignoring: id) else { return }

        // An overlay with no base beneath it is dropped by the solver as an
        // orphan, so accepting the move would make the element vanish with no
        // way to get it back — the drag layer can only show what the solver
        // returns. Refusing the drop leaves it where it was.
        if moved.layer == .overlay {
            let hasBase = layout.placements.contains {
                $0.id != id && $0.layer == .base && $0.row == moved.row
                    && $0.columns.overlaps(moved.columns)
            }
            guard hasBase else { return }
        }

        edit { $0.placements[index] = moved }
    }

    /// Rows must stay contiguous from zero. Dropping onto "one past the last
    /// row" is how you make a new bottom row, and without this that leaves a
    /// gap the solver compacts away — so the saved layout and the drawn one
    /// disagree, and the next drag computes against the wrong rows.
    private func normalisingRows(_ input: SurfaceLayout) -> SurfaceLayout {
        var output = input
        // COVERED rows, not starting rows. An element spanning rows 0-2 owns
        // rows 1 and 2 without starting there; renumbering from start rows
        // alone would delete those rows out from under it and collapse the
        // span — the layout would silently lose its shape on the next edit.
        var covered: Set<Int> = []
        for placement in output.placements { covered.formUnion(placement.rows) }
        let rows = covered.sorted()
        var map: [Int: Int] = [:]
        for (index, row) in rows.enumerated() { map[row] = index }
        for index in output.placements.indices {
            output.placements[index].row = map[output.placements[index].row] ?? 0
        }
        return output
    }

    // MARK: Palette

    private var palette: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add an element").font(.caption).foregroundStyle(.secondary)
            // A wrapping grid, not a horizontal strip. 24 tiles at 64pt plus
            // spacing is 1674pt of content; the pane is 392pt at its minimum,
            // so 19 of the 24 elements could only be reached by scrolling
            // sideways — and a plain mouse has no horizontal wheel. This
            // reflows to zero scrolling as the window widens, and scrolls
            // VERTICALLY when it cannot.
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Self.paletteColumns, spacing: 6) {
                    ForEach(PlayerElement.allCases, id: \.self) { element in
                        Button {
                            add(element)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: element.paletteSymbol)
                                    .font(.system(size: 13))
                                Text(element.paletteLabel)
                                    .font(.system(size: 9))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.primary.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                        .help("Add \(element.paletteLabel) to this surface")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 116)
        }
    }

    private static let paletteColumns = [
        GridItem(.adaptive(minimum: 68, maximum: 110), spacing: 6)
    ]

    /// Place a new element in the first free cell, or on a new bottom row if
    /// there is none.
    private func add(_ element: PlayerElement) {
        var updated = layout
        let span = min(element.metrics.preferredSpan, updated.geometry.columns)
        let rows = (Set(updated.placements.map(\.row)).max() ?? -1) + 1

        var placed: ElementPlacement?
        outer: for row in 0...max(0, rows) {
            for column in 0...(updated.geometry.columns - span) {
                let candidate = ElementPlacement(
                    element: element, col: column, row: row, colSpan: span,
                    priority: element.defaultPriority)
                if GridSolver.canPlace(candidate, in: updated) {
                    placed = candidate
                    break outer
                }
            }
        }
        guard let placement = placed ?? nil else { return }
        edit { $0.placements.append(placement) }
        selection = placement.id
    }

    // MARK: Inspector

    @ViewBuilder private var inspector: some View {
        if let id = selection,
            let index = layout.placements.firstIndex(where: { $0.id == id })
        {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(layout.placements[index].element.paletteLabel)
                        .font(.headline)

                    Picker("Shown", selection: binding(index, \.visibility)) {
                        Text("Always").tag(ElementVisibility.always)
                        Text("On hover").tag(ElementVisibility.onHover)
                    }

                    Picker("Layer", selection: binding(index, \.layer)) {
                        Text("In the grid").tag(ElementLayer.base)
                        Text("On top").tag(ElementLayer.overlay)
                    }
                    Text(
                        layout.placements[index].layer == .overlay
                            ? "Draws over whatever is beneath it and adds no height, so revealing it on hover will not make the surface grow."
                            : "Takes its own space. Revealing this on hover makes the surface taller."
                    )
                    .font(.caption).foregroundStyle(.secondary)

                    // The range is computed first because a `...` split across
                    // lines does not parse inside an argument list.
                    let minimum = layout.placements[index].element.metrics.minSpan
                    let maximum = max(
                        minimum, layout.geometry.columns - layout.placements[index].col)
                    Stepper(
                        "Width: \(layout.placements[index].colSpan) of \(layout.geometry.columns)",
                        value: binding(index, \.colSpan, appliesToSelection: false),
                        in: minimum...maximum)

                    // Height in ROWS. A span that is legal here can overflow
                    // the grid for another element further right, so like
                    // width it never fans out across a multi-selection.
                    Stepper(
                        "Height: \(layout.placements[index].rowSpan) row\(layout.placements[index].rowSpan == 1 ? "" : "s")",
                        value: binding(index, \.rowSpan, appliesToSelection: false), in: 1...6)
                    Text("Taller than one row lets an element sit beside a stack of others — how the full-screen player puts lyrics next to the artwork.")
                        .font(.caption).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 3) {
                        Stepper(
                            "Priority: \(layout.placements[index].priority)",
                            value: binding(index, \.priority), in: 0...9)
                        Text(
                            layout.placements[index].priority == 0
                                ? "Never removed, however small the surface gets."
                                : "Higher numbers are removed first as the surface shrinks."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }

                    // Per-element controls, the same shape as the artwork
                    // style block below. The bar count was reachable only from
                    // the Player pane, nowhere near the element it draws.
                    if layout.placements[index].element == .visualizer {
                        Divider()
                        Stepper(
                            "Bars: \(visualizerBars)", value: $visualizerBars, in: 1...16)
                        Toggle("Colour from the album", isOn: $colouredBars)
                    }

                    if layout.placements[index].element == .artwork {
                        Divider()
                        Picker("Style", selection: binding(index, \.artworkStyle.kind)) {
                            Text("Album cover").tag(ArtworkStyle.Kind.cover)
                            Text("Vinyl record").tag(ArtworkStyle.Kind.vinyl)
                        }
                        if layout.placements[index].artworkStyle.kind == .vinyl {
                            Toggle("Tonearm", isOn: binding(index, \.artworkStyle.showsStylus))
                            Toggle(
                                "Progress ring around the record",
                                isOn: binding(index, \.artworkStyle.showsProgressRing))
                        }
                    }

                    Divider()
                    Button(role: .destructive) {
                        removeSelected()
                    } label: {
                        Label(
                            selectedIDs.count > 1
                                ? "Remove \(selectedIDs.count) elements"
                                : "Remove from this surface",
                            systemImage: "trash")
                    }

                    Spacer(minLength: 0)
                }
                .padding(14)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("Select an element in the preview")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Drag it to move it. Add more from the row below.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxHeight: .infinity)
        }
    }

    /// Reads from the primary selection, writes to ALL of it.
    ///
    /// Setting a priority or a visibility with six buttons ⌘-selected should
    /// set six priorities. Span is deliberately excluded from the fan-out by
    /// its caller, because a span that is legal for one element can overflow
    /// the grid for another sitting further right.
    private func binding<Value>(
        _ index: Int, _ path: WritableKeyPath<ElementPlacement, Value>,
        appliesToSelection: Bool = true
    ) -> Binding<Value> {
        Binding(
            get: { layouts[surface].placements[index][keyPath: path] },
            set: { newValue in
                let targets = appliesToSelection ? selectedIDs : []
                edit { draft in
                    if targets.count > 1 {
                        for i in draft.placements.indices
                        where targets.contains(draft.placements[i].id) {
                            draft.placements[i][keyPath: path] = newValue
                        }
                    } else if draft.placements.indices.contains(index) {
                        draft.placements[index][keyPath: path] = newValue
                    }
                }
            })
    }
}

// MARK: - Palette metadata

extension PlayerElement {
    var paletteLabel: String {
        switch self {
        case .artwork: return "Artwork"
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .playPause: return "Play"
        case .next: return "Next"
        case .previous: return "Previous"
        case .seekBackward: return "Back 10s"
        case .seekForward: return "Skip 10s"
        case .shuffle: return "Shuffle"
        case .repeatMode: return "Repeat"
        case .progressBar: return "Progress"
        case .timeElapsed: return "Elapsed"
        case .timeRemaining: return "Remaining"
        case .trackTimeToggle: return "Time"
        case .lyrics: return "Lyrics"
        case .outputDevice: return "Output"
        case .airPlay: return "AirPlay"
        case .volumeSlider: return "Volume"
        case .visualizer: return "Visualiser"
        case .appIcon: return "App icon"
        case .explicitBadge: return "Explicit"
        case .clock: return "Clock"
        case .timer: return "Timer"
        }
    }

    var paletteSymbol: String {
        switch self {
        case .artwork: return "opticaldisc"
        case .title: return "textformat"
        case .artist: return "person"
        case .album: return "square.stack"
        case .playPause: return "play.fill"
        case .next: return "forward.end.fill"
        case .previous: return "backward.end.fill"
        case .seekBackward: return "gobackward.10"
        case .seekForward: return "goforward.10"
        case .shuffle: return "shuffle"
        case .repeatMode: return "repeat"
        case .progressBar: return "slider.horizontal.below.rectangle"
        case .timeElapsed: return "clock.arrow.circlepath"
        case .timeRemaining: return "clock.badge.checkmark"
        case .trackTimeToggle: return "clock.arrow.2.circlepath"
        case .lyrics: return "quote.bubble"
        case .outputDevice: return "hifispeaker"
        case .airPlay: return "airplayaudio"
        case .volumeSlider: return "speaker.wave.2"
        case .visualizer: return "waveform"
        case .appIcon: return "app"
        case .explicitBadge: return "e.square"
        case .clock: return "clock"
        case .timer: return "timer"
        }
    }

    /// Where a newly added element sits in the drop order.
    ///
    /// Nothing added from the palette is priority 0: an element the user just
    /// placed should not outrank the artwork and play button that were there
    /// first, and they can promote it in the inspector.
    var defaultPriority: Int {
        switch self {
        case .artwork, .playPause: return 1
        case .title, .progressBar: return 3
        case .artist, .next, .previous: return 4
        default: return 6
        }
    }
}
