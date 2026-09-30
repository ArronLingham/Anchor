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

import CoreGraphics
import Foundation

/// Turns a saved `SurfaceLayout` into frames.
///
/// Pure — Foundation and CoreGraphics only, no SwiftUI, no AppKit, no
/// `Defaults`. That is not tidiness: it is what lets `tests/run_gridsolver_tests.sh`
/// compile this exact file with `swiftc` and assert against it, so the harness
/// cannot drift from the implementation the way a re-typed copy would.
public enum GridSolver {

    // MARK: - Output

    public struct ResolvedElement: Equatable, Sendable {
        public let placement: ElementPlacement
        public let frame: CGRect
    }

    public struct ResolvedLayout: Equatable, Sendable {
        /// Draw order: every `base` element, then every `overlay`, so an overlay
        /// always paints on top of the thing it sits on without the renderer
        /// needing a z-index.
        public let elements: [ResolvedElement]
        /// What this arrangement needs. The desktop widget's window height comes
        /// from here, and hover growth is the difference between two of these.
        public let requiredSize: CGSize
        /// Placement ids that were left out, either because they did not fit or
        /// because the base element they sat on did not.
        public let dropped: [UUID]
        /// Height of each row after compaction, top to bottom. The settings
        /// editor needs this to map a drag position back to a cell.
        public let rowHeights: [CGFloat]

        public func frame(for id: UUID) -> CGRect? {
            elements.first { $0.placement.id == id }?.frame
        }
    }

    // MARK: - Memoisation

    /// Cache key. `SurfaceLayout` is `Hashable`, so this is cheap to form and
    /// exact — no fingerprinting, no chance of a stale hit.
    private struct SolveKey: Hashable {
        let layout: SurfaceLayout
        let width: CGFloat
        let height: CGFloat
        let hovering: Bool
    }

    /// `solve` is called from inside a SwiftUI `body`, under a `GeometryReader`,
    /// on a surface that re-renders on every drag frame and every playback
    /// publish. Each call allocates on the order of a hundred small collections
    /// — sorts, sets, dictionaries, three array passes.
    ///
    /// The inputs are almost always identical between those calls: the layout
    /// changes when the user edits it, the size when they resize, and neither
    /// happens per frame. So the answer is memoised.
    ///
    /// The cache is deliberately tiny and unordered-evicting. A surface has one
    /// live (layout, size, hovering) combination and at most a second while a
    /// hover animation runs; anything beyond that is a resize in flight, where
    /// every key is new and a cache of any size would miss anyway. An LRU would
    /// cost more bookkeeping than it saves.
    private static let cacheLimit = 16
    private static var cache: [SolveKey: ResolvedLayout] = [:]
    private static let cacheLock = NSLock()

    private static func cached(_ key: SolveKey) -> ResolvedLayout? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private static func store(_ value: ResolvedLayout, for key: SolveKey) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
    }

    // MARK: - Solve

    /// - Parameters:
    ///   - available: `height` may be `.infinity`, which means "tell me what
    ///     this wants" and disables dropping entirely. That is how hover growth
    ///     is measured, and it matters: measuring at a finite height would let
    ///     the drop loop interact with the growth decision and oscillate.
    public static func solve(
        layout: SurfaceLayout,
        available: CGSize,
        hovering: Bool
    ) -> ResolvedLayout {
        let key = SolveKey(
            layout: layout, width: available.width, height: available.height, hovering: hovering)
        if let hit = cached(key) { return hit }
        let result = computeSolve(layout: layout, available: available, hovering: hovering)
        store(result, for: key)
        return result
    }

    private static func computeSolve(
        layout: SurfaceLayout,
        available: CGSize,
        hovering: Bool
    ) -> ResolvedLayout {
        let geometry = layout.geometry
        let columns = max(1, geometry.columns)

        // 1. Normalise. A placement can arrive malformed from hand-edited JSON,
        //    from a layout saved when the surface had more columns, or from a
        //    future version. Clamp rather than trap — a player that refuses to
        //    draw is worse than one that draws a slightly wrong arrangement.
        var placements = layout.placements.compactMap { p -> ElementPlacement? in
            var p = p
            guard p.row >= 0 else { return nil }
            p.col = min(max(0, p.col), columns - 1)
            let maxSpan = columns - p.col
            p.colSpan = min(max(p.element.metrics.minSpan, p.colSpan), maxSpan)
            return p
        }

        // 2. Visibility. Resting is `.always`; hovering adds `.onHover`.
        placements = placements.filter { $0.visibility == .always || hovering }

        // 3. Resolve overlaps between BASE placements. Two of them may not share
        //    a cell; an overlay sitting on a base one is the whole point of the
        //    layer distinction. First-come wins, ordered by row then column, so
        //    the result is deterministic rather than dependent on array order.
        placements = removeBaseOverlaps(placements)

        let cellWidth = cellWidth(for: geometry, totalWidth: available.width)

        // 4. Drop to fit. Only when a real height was given.
        var dropped: [UUID] = []
        if available.height.isFinite {
            dropped = dropToFit(&placements, geometry: geometry, cellWidth: cellWidth,
                                limit: available.height)
        }

        // 5. An overlay whose base is gone would float on nothing — a play
        //    button hanging in space where the artwork used to be. Drop it too.
        //    This runs after the fit loop because that loop is what removes
        //    bases; running it before would miss exactly the case it exists for.
        let orphans = removeOrphanedOverlays(&placements)
        dropped.append(contentsOf: orphans)

        // 6. Compact. Deleting a row must move every placement below it up,
        //    overlays included, or an overlay separates from its base.
        let rowMap = compact(&placements)

        // 7. Frames.
        let heights = rowHeights(placements, cellWidth: cellWidth, gutter: geometry.gutter, scale: geometry.contentScale)
        var resolved = frames(
            placements, geometry: geometry, cellWidth: cellWidth, rowHeights: heights)
        if geometry.centersContent {
            resolved = centred(
                resolved, in: available, geometry: geometry,
                contentHeight: totalHeight(heights, geometry: geometry))
        }

        _ = rowMap
        return ResolvedLayout(
            elements: resolved,
            requiredSize: CGSize(
                width: available.width,
                height: totalHeight(heights, geometry: geometry)),
            dropped: dropped,
            rowHeights: heights)
    }

    // MARK: - Hover

    public struct HoverMetrics: Equatable, Sendable {
        public let restingHeight: CGFloat
        public let hoverHeight: CGFloat
        /// Whether revealing the hover elements needs more room than the
        /// resting arrangement has.
        public var grows: Bool { hoverHeight > restingHeight + 0.5 }
    }

    /// Whether hovering makes this surface taller, and by how much.
    ///
    /// Derived, never configured. The user marks an element `.always` or
    /// `.onHover` and this works out the consequence: a hover-only play button
    /// placed as an `overlay` on the artwork adds no row and nothing moves,
    /// while a hover-only progress bar placed as `base` on its own row makes
    /// the window grow. That is the stated requirement.
    ///
    /// Both measurements are taken at unbounded height on purpose. Measuring at
    /// the window's current height would let the drop loop participate: growing
    /// would move the window edge, which can move the pointer out of the
    /// surface, which un-hovers it, which shrinks it back under the pointer —
    /// a visible flutter with no stable state.
    public static func hoverMetrics(layout: SurfaceLayout, width: CGFloat) -> HoverMetrics {
        let unbounded = CGSize(width: width, height: .infinity)
        return HoverMetrics(
            restingHeight: solve(layout: layout, available: unbounded, hovering: false)
                .requiredSize.height,
            hoverHeight: solve(layout: layout, available: unbounded, hovering: true)
                .requiredSize.height)
    }

    /// The smallest height at which nothing is dropped — the floor a resize
    /// drag should clamp to before it starts costing the user elements.
    public static func intrinsicHeight(layout: SurfaceLayout, width: CGFloat, hovering: Bool = false)
        -> CGFloat
    {
        solve(layout: layout, available: CGSize(width: width, height: .infinity), hovering: hovering)
            .requiredSize.height
    }

    // MARK: - Editor support

    /// Whether `candidate` can be dropped where it says it wants to go.
    ///
    /// The settings editor asks this on every drag frame, so it must be cheap
    /// and must not allocate a solve.
    public static func canPlace(
        _ candidate: ElementPlacement, in layout: SurfaceLayout, ignoring ignoredID: UUID? = nil
    ) -> Bool {
        let columns = max(1, layout.geometry.columns)
        guard candidate.row >= 0, candidate.col >= 0,
            candidate.col + candidate.colSpan <= columns,
            candidate.colSpan >= candidate.element.metrics.minSpan
        else { return false }
        // An overlay may land on anything. Only base-on-base is a conflict.
        guard candidate.layer == .base else { return true }
        return !layout.placements.contains { existing in
            existing.id != ignoredID
                && existing.id != candidate.id
                && existing.layer == .base
                // Rows OVERLAP rather than match: a placement spanning rows 0-2
                // conflicts with anything in row 1, which row equality misses.
                && existing.rows.overlaps(candidate.rows)
                && existing.columns.overlaps(candidate.columns)
        }
    }

    /// Cells on `row` with no base placement, for the editor's drop highlight.
    public static func freeColumns(on row: Int, in layout: SurfaceLayout, ignoring ignoredID: UUID? = nil)
        -> [Int]
    {
        let taken = Set(
            layout.placements
                .filter { $0.layer == .base && $0.row == row && $0.id != ignoredID }
                .flatMap { $0.columns })
        return (0..<max(1, layout.geometry.columns)).filter { !taken.contains($0) }
    }

    /// Map a point in the surface back to a grid cell, for drag-and-drop.
    ///
    /// Returns `nil` outside the content area. `row` may be one past the last
    /// occupied row, which is how you drag something onto a new bottom row.
    /// Where a drop lands: on a cell, or in the seam BETWEEN two rows.
    ///
    /// The seam case is the whole reason this exists. `cell(at:)` can only
    /// answer with an existing row index or one-past-the-end, so the only way
    /// to make a row was to drop below everything — there was no way to insert
    /// between two rows at all, and `normalisingRows` renumbers contiguously
    /// after every edit so a gap cannot even be expressed transiently.
    public enum DropTarget: Equatable, Sendable {
        case cell(col: Int, row: Int)
        /// Open a new row immediately before `before`, and land there.
        case seam(col: Int, before: Int)
    }

    /// `seamBand` is how close to a row boundary counts as "between". It is
    /// generous on purpose: a seam the width of a hairline is a seam nobody can
    /// hit, and the reported symptom was that dragging felt finicky.
    public static func dropTarget(
        at point: CGPoint, geometry: GridGeometry, totalWidth: CGFloat,
        rowHeights: [CGFloat], seamBand: CGFloat = 10
    ) -> DropTarget? {
        let columns = max(1, geometry.columns)
        let cw = cellWidth(for: geometry, totalWidth: totalWidth)
        guard cw > 0 else { return nil }
        let x = point.x - geometry.padding
        let col = min(columns - 1, max(0, Int(max(0, x) / (cw + geometry.gutter))))

        // Row boundaries in the same coordinate space the renderer used.
        var boundaries: [CGFloat] = [geometry.padding]
        var y = geometry.padding
        for height in rowHeights {
            y += height
            boundaries.append(y)
            y += geometry.gutter
        }

        for (index, edge) in boundaries.enumerated() where abs(point.y - edge) <= seamBand {
            // The seam above row 0 inserts at 0; the seam below the last row is
            // just "append", which `cell` already handled, so both ends work.
            return .seam(col: col, before: index)
        }

        guard let hit = cell(
            at: point, geometry: geometry, totalWidth: totalWidth, rowHeights: rowHeights)
        else { return nil }
        return .cell(col: hit.col, row: hit.row)
    }

    public static func cell(
        at point: CGPoint, geometry: GridGeometry, totalWidth: CGFloat, rowHeights: [CGFloat]
    ) -> (col: Int, row: Int)? {
        let columns = max(1, geometry.columns)
        let cw = cellWidth(for: geometry, totalWidth: totalWidth)
        guard cw > 0 else { return nil }
        let x = point.x - geometry.padding
        guard x >= 0 else { return nil }
        let col = min(columns - 1, Int(x / (cw + geometry.gutter)))

        var y = point.y - geometry.padding
        guard y >= 0 else { return nil }
        for (index, height) in rowHeights.enumerated() {
            if y <= height { return (col, index) }
            y -= height + geometry.gutter
        }
        return (col, rowHeights.count)
    }

    // MARK: - Geometry

    static func cellWidth(for geometry: GridGeometry, totalWidth: CGFloat) -> CGFloat {
        let columns = CGFloat(max(1, geometry.columns))
        let content = totalWidth - geometry.padding * 2 - geometry.gutter * (columns - 1)
        return max(0, content / columns)
    }

    /// Width an element ends up with, spanning `span` columns — the cells plus
    /// the gutters it swallows between them.
    static func resolvedWidth(span: Int, cellWidth: CGFloat, gutter: CGFloat) -> CGFloat {
        CGFloat(span) * cellWidth + CGFloat(max(0, span - 1)) * gutter
    }

    /// Height of every occupied row, in row order.
    ///
    /// Only `base` elements contribute. An overlay adds no height — that is the
    /// mechanism the whole hover requirement rests on.
    ///
    /// This generalises `VinylWidgetSize.height(width:orientation:showsTitle:showsProgress:)`,
    /// which does the same job for four hardcoded rows. It exists because the
    /// height there was once a fixed 1.36 ratio, so switching the progress bar
    /// off left an empty strip at the bottom of the card instead of making it
    /// shorter.
    static func rowHeights(
        _ placements: [ElementPlacement], cellWidth: CGFloat, gutter: CGFloat,
        scale: CGFloat = 1
    ) -> [CGFloat] {
        guard let maxRow = placements.map({ $0.rows.upperBound - 1 }).max() else { return [] }

        func need(_ p: ElementPlacement) -> CGFloat {
            let width = resolvedWidth(span: p.colSpan, cellWidth: cellWidth, gutter: gutter)
            // Artwork is square, so its height IS its width and must not be
            // scaled again — it already grew with the cells.
            return p.element.metrics.growsVertically
                ? p.element.metrics.height(width)
                : p.element.metrics.height(width) * scale
        }

        // Single-row placements set the baseline.
        var heights = (0...maxRow).map { row in
            placements
                .filter { $0.rowSpan == 1 && $0.row == row && $0.layer == .base }
                .map(need)
                .max() ?? 0
        }

        // A spanning placement does NOT force one row to be tall. It only has to
        // fit across the rows it covers, gutters included; any shortfall is
        // spread evenly over them. Giving its whole height to its first row
        // would make a 4-row lyrics column produce one enormous row and three
        // empty ones.
        for p in placements where p.layer == .base && p.rowSpan > 1 {
            let rows = p.rows.clamped(to: 0..<heights.count)
            guard !rows.isEmpty else { continue }
            let gutters = gutter * CGFloat(rows.count - 1)
            let available = rows.reduce(0) { $0 + heights[$1] } + gutters
            let deficit = need(p) - available
            guard deficit > 0 else { continue }
            let share = deficit / CGFloat(rows.count)
            for row in rows { heights[row] += share }
        }
        return heights
    }

    static func totalHeight(_ rowHeights: [CGFloat], geometry: GridGeometry) -> CGFloat {
        guard !rowHeights.isEmpty else { return geometry.padding * 2 }
        let gutters = geometry.gutter * CGFloat(rowHeights.count - 1)
        return rowHeights.reduce(0, +) + gutters + geometry.padding * 2
    }

    // MARK: - Stages

    /// Keep the first base placement in any contested cell, drop the rest.
    /// Sorted first so "first" means top-left, not whatever order the array
    /// happened to be in.
    private static func removeBaseOverlaps(_ placements: [ElementPlacement]) -> [ElementPlacement] {
        var occupied: [Int: Set<Int>] = [:]
        var kept: [ElementPlacement] = []
        for p in placements.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }) {
            guard p.layer == .base else { kept.append(p); continue }
            // Free only if EVERY row it spans is free across its columns, and
            // then all of them are marked. Checking the first row alone would
            // let a tall element be overwritten from its second row down.
            let fits = p.rows.allSatisfy { row in
                (occupied[row] ?? []).isDisjoint(with: p.columns)
            }
            if fits {
                for row in p.rows { occupied[row, default: []].formUnion(p.columns) }
                kept.append(p)
            }
        }
        return kept
    }

    /// Remove placements, highest `priority` value first, until the arrangement
    /// fits — or until only priority-0 elements remain.
    ///
    /// Priority 0 is never dropped, which is what makes this terminate. If the
    /// priority-0 set alone still does not fit, the surface is simply too small
    /// and the caller draws it clipped: silently blanking the player would be
    /// worse than showing a cramped one.
    ///
    /// Ties are broken by row then column, bottom-right first, so two elements
    /// sharing a priority drop in a stable, predictable order rather than
    /// whichever the sort happened to reach.
    private static func dropToFit(
        _ placements: inout [ElementPlacement],
        geometry: GridGeometry,
        cellWidth: CGFloat,
        limit: CGFloat
    ) -> [UUID] {
        var dropped: [UUID] = []
        while true {
            let heights = rowHeights(placements, cellWidth: cellWidth, gutter: geometry.gutter, scale: geometry.contentScale)
            guard totalHeight(heights, geometry: geometry) > limit else { break }
            let candidates = placements.filter { $0.priority > 0 }
            guard !candidates.isEmpty else { break }
            let victim = candidates.max {
                ($0.priority, $0.row, $0.col) < ($1.priority, $1.row, $1.col)
            }!
            placements.removeAll { $0.id == victim.id }
            dropped.append(victim.id)
        }
        return dropped
    }

    /// An overlay is anchored to whatever base placement it sits on. If that
    /// base is gone, so is the overlay.
    private static func removeOrphanedOverlays(_ placements: inout [ElementPlacement]) -> [UUID] {
        let bases = placements.filter { $0.layer == .base }
        var orphaned: [UUID] = []
        placements.removeAll { p in
            guard p.layer == .overlay else { return false }
            let hasBase = bases.contains { $0.row == p.row && $0.columns.overlaps(p.columns) }
            if !hasBase { orphaned.append(p.id) }
            return !hasBase
        }
        return orphaned
    }

    /// Close up rows left empty by dropping, and renumber what remains from 0.
    ///
    /// Applied to every placement including overlays, from one shared mapping —
    /// compacting bases and overlays separately is how an overlay ends up on a
    /// different row from the thing it was drawn on top of.
    @discardableResult
    private static func compact(_ placements: inout [ElementPlacement]) -> [Int: Int] {
        // COVERED rows, not starting rows. A placement spanning rows 0-2 owns
        // rows 1 and 2 without starting there; treating those as empty deletes
        // them out from under it, and the span silently collapses the first
        // time anything is dropped above it.
        var coveredRows: Set<Int> = []
        for placement in placements { coveredRows.formUnion(placement.rows) }
        let occupied = coveredRows.sorted()
        var map: [Int: Int] = [:]
        for (newIndex, oldRow) in occupied.enumerated() { map[oldRow] = newIndex }
        for index in placements.indices {
            placements[index].row = map[placements[index].row] ?? placements[index].row
        }
        return map
    }

    /// Centre each row horizontally and the whole block vertically.
    ///
    /// Rows are shifted as a unit so an overlay keeps its position over the base
    /// it sits on — shifting the two independently is the same mistake as
    /// compacting them independently, and separates a play button from its
    /// artwork.
    private static func centred(
        _ elements: [ResolvedElement], in available: CGSize, geometry: GridGeometry,
        contentHeight: CGFloat
    ) -> [ResolvedElement] {
        var byRow: [Int: (minX: CGFloat, maxX: CGFloat)] = [:]
        for element in elements where element.placement.layer == .base {
            let row = element.placement.row
            let existing = byRow[row] ?? (element.frame.minX, element.frame.maxX)
            byRow[row] = (
                min(existing.minX, element.frame.minX), max(existing.maxX, element.frame.maxX))
        }

        let dy: CGFloat =
            available.height.isFinite && available.height > contentHeight
            ? (available.height - contentHeight) / 2 : 0

        return elements.map { element in
            guard let extent = byRow[element.placement.row] else { return element }
            let used = extent.maxX - extent.minX
            let dx = (available.width - used) / 2 - extent.minX
            var frame = element.frame
            frame.origin.x += dx
            frame.origin.y += dy
            return ResolvedElement(placement: element.placement, frame: frame)
        }
    }

    private static func frames(
        _ placements: [ElementPlacement],
        geometry: GridGeometry,
        cellWidth: CGFloat,
        rowHeights: [CGFloat]
    ) -> [ResolvedElement] {
        var rowOrigins: [CGFloat] = []
        var y = geometry.padding
        for height in rowHeights {
            rowOrigins.append(y)
            y += height + geometry.gutter
        }

        // Bases first, overlays second: draw order, so the renderer needs no
        // z-index of its own.
        let ordered = placements.sorted { a, b in
            if a.layer != b.layer { return a.layer == .base }
            return (a.row, a.col) < (b.row, b.col)
        }

        return ordered.compactMap { p in
            guard p.row < rowOrigins.count else { return nil }
            let width = resolvedWidth(span: p.colSpan, cellWidth: cellWidth, gutter: geometry.gutter)
            let x = geometry.padding + CGFloat(p.col) * (cellWidth + geometry.gutter)
            // A spanning placement's box is every row it covers plus the
            // gutters BETWEEN them — the gutters become usable space rather
            // than dead bands through the middle of a tall element.
            let spanned = p.rows.clamped(to: 0..<rowHeights.count)
            let rowHeight =
                spanned.isEmpty
                ? rowHeights[p.row]
                : spanned.reduce(0) { $0 + rowHeights[$1] }
                    + geometry.gutter * CGFloat(spanned.count - 1)
            let metrics = p.element.metrics

            // An element that does not grow keeps its intrinsic size and is
            // centred in the space it was given, rather than being stretched.
            // A stretched play button is a 90pt-wide tap target that looks
            // wrong next to a 30pt one.
            let scaled = metrics.growsVertically
                ? metrics.height(width) : metrics.height(width) * geometry.contentScale
            // A multi-row placement FILLS the box it reserved. Capping it at the
            // element's intrinsic height would reserve four rows of space and
            // then draw one row of content in the middle of them, which is the
            // reserve-but-don't-use bug the assertion "a spanned frame covers
            // its rows" exists to catch. Asking for N rows is the request.
            let elementHeight = p.rowSpan > 1 ? rowHeight : min(scaled, rowHeight)
            let frame: CGRect
            if metrics.growsHorizontally {
                frame = CGRect(
                    x: x, y: rowOrigins[p.row] + (rowHeight - elementHeight) / 2,
                    width: width, height: elementHeight)
            } else {
                // Square elements centre in whatever box they were given — one
                // row, or the taller span. `elementHeight` already accounts for
                // the difference, so there is one branch, not two.

                let intrinsic = min(elementHeight, width)
                frame = CGRect(
                    x: x + (width - intrinsic) / 2,
                    y: rowOrigins[p.row] + (rowHeight - intrinsic) / 2,
                    width: intrinsic, height: intrinsic)
            }
            return ResolvedElement(placement: p, frame: frame)
        }
    }
}

// Tuple comparison used above for stable ordering.
private func < (lhs: (Int, Int), rhs: (Int, Int)) -> Bool {
    lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
}

private func < (lhs: (Int, Int, Int), rhs: (Int, Int, Int)) -> Bool {
    if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
    if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
    return lhs.2 < rhs.2
}

extension Range where Bound == Int {
    /// `Set.isDisjoint(with:)` takes a Sequence, so a Range works directly, but
    /// overlap reads better than its negation at the call sites above.
    func overlaps(_ other: Range<Int>) -> Bool {
        lowerBound < other.upperBound && other.lowerBound < upperBound
    }
}
