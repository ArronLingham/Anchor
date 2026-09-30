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

// The starting arrangement for each surface.
//
// These are NOT designs. Each one is a transcription of what that surface
// actually draws today, expressed in the grid, so that a user opening the
// editor for the first time sees the player they already had and edits from
// there. Where a surface has no equivalent of a grid element, the note on the
// placement says so.
//
// Derived by reading, in order:
//   desktop     Sources/Vinyl/VinylWidgetView.swift + VinylWidgetWindowManager.swift
//   lockWidget  Anchor's Components/LockScreen/LockScreenMusicPanel.swift, collapsed state
//   lockFull    Anchor's Components/LockScreen/LockScreenImmersivePlayer.swift
//   launcher    Anchor's Components/Launcher/LauncherWidgets.swift
//
// Placement ids are deterministic rather than random. A fresh `UUID()` per
// launch would make every default layout a different value, so `Defaults`
// would see a change and write on every start, and two machines syncing the
// same settings would fight. Seeded ids also mean a test can name a placement.

extension PlayerLayouts {
    /// What a first launch gets.
    public static let defaults = PlayerLayouts(
        desktop: .defaultDesktop,
        lockWidget: .defaultLockWidget,
        lockFull: .defaultLockFull,
        desktopFull: .defaultLockFull,
        launcher: .defaultLauncher)
}

extension SurfaceLayout {

    /// The vinyl widget as it stands: record, title, artist and album, transport,
    /// then a progress bar with times beneath it.
    ///
    /// Six rows where `VinylWidgetView` has four blocks, because two of its
    /// blocks are internally two lines — title over subtitle, and bar over
    /// times. Splitting them is strictly finer-grained than the source's own
    /// `showTitle` / `showProgress` toggles, which collapse each pair together.
    ///
    /// The transport sits at columns 1-4 rather than spread across all six,
    /// which reproduces the source's centred cluster: its `HStack` is about
    /// 0.41W wide inside 0.85W of content, so the outer columns stay empty.
    /// `playPause` spans two columns because its glyph is `width * 0.082`
    /// against its neighbours' `0.062`, and a two-column span puts its centre
    /// at exactly half the card.
    ///
    /// The alternative ring progress style is this same `progressBar`
    /// placement moved to row 0 as an `overlay`, where it adds no height —
    /// which is exactly what `VinylWidgetSize.height` already does by adding
    /// the bar's allowance only when the style is `.bar`. The source is its own
    /// proof of the base/overlay rule.
    public static let defaultDesktop = SurfaceLayout(
        geometry: GridGeometry(columns: 6),
        placements: [
            // The record. Style .vinyl. width*0.72 square, centred in a turntable
            // frame of (recordSide + width*0.10) x recordSide = 0.82W x 0.72W, against
            // 0.85W of content width. The tonearm (showStylus, default on) has no
            // PlayerElement of its own — it is part of the .vinyl rendering, drawn
            // inside the same ZStack and inside the 0.72W frame, so it adds no height
            // and does not change these metrics. Interactive: tapping the record
            // toggles play/pause, so isInteractive must be true and artwork is
            // excluded from double-click-send-to-back. rowSpan is 1 here even though
            // the element is tall — nothing sits beside it on this surface, and its
            // tallness comes from height(), not from occupying grid rows; a rowSpan >
            // 1 would collide with title/artist/transport below.
            ElementPlacement(
                id: UUID(uuidString: "de5c0000-0000-4000-8000-000000000000")!,
                element: .artwork, col: 0, row: 0, colSpan: 6,
                layer: .base, visibility: .always, priority: 0, artworkStyle: .vinyl),
            // music.songTitle. font width*0.062 semibold, lineLimit 1, truncationMode
            // .tail, centred via .frame(maxWidth: .infinity). growsHorizontally.
            // Together with row 2 this is the source's trackLabels block, charged
            // 0.17W by the height formula.
            ElementPlacement(
                id: UUID(uuidString: "de5c0000-0000-4000-8000-000000000001")!,
                element: .title, col: 0, row: 1, colSpan: 6,
                layer: .base, visibility: .always, priority: 1),
            // NO EXACT EQUIVALENT TODAY. The source draws ONE combined centred
            // subtitle at font width*0.048: `artist – album`, collapsing to bare
            // artist when album is empty or equals artist. The grid has no combined
            // element, so the line is split across one row, artist taking the left
            // half. Deleting album from this layout reproduces the source's own
            // fallback exactly.
            ElementPlacement(
                id: UUID(uuidString: "de5c0000-0000-4000-8000-000000000002")!,
                element: .artist, col: 0, row: 2, colSpan: 3,
                layer: .base, visibility: .always, priority: 4),
            // Right half of the same combined subtitle line — see the artist note.
            // Highest priority value, so it is the first thing to go, which is
            // precisely the degradation the source already performs on its own when
            // the album is redundant.
            ElementPlacement(
                id: UUID(uuidString: "de5c0000-0000-4000-8000-000000000003")!,
                element: .album, col: 3, row: 2, colSpan: 3,
                layer: .base, visibility: .always, priority: 6),
            // backward.end.fill at font width*0.062 weight .medium. Col 1 (not 0)
            // reproduces the source's centred cluster: the HStack is 0.41W wide inside
            // 0.85W of content, so the outer columns stay empty. Priority 2 rather
            // than a higher value because VinylWidgetSize.height comments this row
            // `transport, always shown` and it is the only block with no user toggle.
            ElementPlacement(
                id: UUID(uuidString: "de5c0000-0000-4000-8000-000000000004")!,
                element: .previous, col: 1, row: 3, colSpan: 1,
                layer: .base, visibility: .always, priority: 2),
            // pause.fill / play.fill at font width*0.082 — noticeably larger than its
            // neighbours, hence the 2-column span, which also places its centre at
            // exactly 0.5W. Priority 0: the last control standing. Note the record
            // itself is a second, far larger play/pause target, so this button and the
            // artwork duplicate one action by design.
            ElementPlacement(
                id: UUID(uuidString: "de5c0000-0000-4000-8000-000000000005")!,
                element: .playPause, col: 2, row: 3, colSpan: 2,
                layer: .base, visibility: .always, priority: 0),
            // forward.end.fill at font width*0.062 weight .medium. Mirror of previous;
            // same priority reasoning.
            ElementPlacement(
                id: UUID(uuidString: "de5c0000-0000-4000-8000-000000000006")!,
                element: .next, col: 4, row: 3, colSpan: 1,
                layer: .base, visibility: .always, priority: 2),
            // Default progressStyle is .bar (MusicDefaults line 72), so it is BASE on
            // its own row and therefore contributes height — the source agrees:
            // height() adds its 0.11W allowance only when showProgress &&
            // progressStyle == .bar. Full-bleed capsule, track height a FIXED 2.5pt
            // inside a hit area of max(8, width*0.03); interactive (onTapGesture seeks
            // by location.x / bar.width). Switching to the ring style is this same
            // placement moved to row 0, layer overlay, where it draws at side =
            // recordSide + width*0.045 with lineWidth 3 and adds no height.
            ElementPlacement(
                id: UUID(uuidString: "de5c0000-0000-4000-8000-000000000007")!,
                element: .progressBar, col: 0, row: 4, colSpan: 6,
                layer: .base, visibility: .always, priority: 3),
            // Left half of the source's `HStack { elapsed; Spacer(); -remaining }`.
            // font width*0.036 weight .medium, monospacedDigit, format %02d:%02d. Cols
            // 2-3 are deliberately left empty — that is the Spacer. Drops before the
            // bar it labels, never after.
            ElementPlacement(
                id: UUID(uuidString: "de5c0000-0000-4000-8000-000000000008")!,
                element: .timeElapsed, col: 0, row: 5, colSpan: 2,
                layer: .base, visibility: .always, priority: 5),
            // Right half of the same row. Source renders it as a COUNTDOWN with a
            // literal leading minus: "-" + timestamp(songDuration - elapsedTime) — not
            // total duration. There is no trackTimeToggle on this surface today; the
            // source offers no way to swap remaining for total, so that element is
            // absent from the default.
            ElementPlacement(
                id: UUID(uuidString: "de5c0000-0000-4000-8000-000000000009")!,
                element: .timeRemaining, col: 4, row: 5, colSpan: 2,
                layer: .base, visibility: .always, priority: 5),
        ])

    /// `LockScreenMusicPanel`'s collapsed state: artwork and title on one line
    /// with the visualiser, artist beneath, then progress flanked by its times,
    /// then the full transport row including shuffle and repeat.
    ///
    /// Only the collapsed state. The panel's expanded (720x340) and immersive
    /// states are separate behaviours, not layouts, and the immersive one is
    /// `lockFull` below.
    public static let defaultLockWidget = SurfaceLayout(
        // centersContent, which this surface never set. The panel is a fixed
        // width the user picks, so without it the arrangement sat hard against
        // the leading edge with the slack all on one side — the reported
        // "content isn't properly centred".
        geometry: GridGeometry(columns: 6, centersContent: true),
        placements: [
            // albumArtButton(size: 60, cornerRadius: 16) — a 60x60 square, style
            // .cover. Needs ElementMetrics.rowSpan 2 so it flanks both title and
            // artist, reproducing the header's fixed .frame(height: 60). 60pt of the
            // 310pt content box is ~19%, i.e. one column of six. Tap opens the
            // immersive player, right-click expands to fullscreen artwork; neither
            // affects layout.
            ElementPlacement(
                id: UUID(uuidString: "10cbd000-0000-4000-8000-000000000000")!,
                element: .artwork, col: 0, row: 0, colSpan: 1,
                layer: .base, visibility: .always, priority: 0, artworkStyle: .cover),
            // MusicTitleMarqueeView, .system(size: 12, weight: .semibold), single
            // line, marquees when the measured text exceeds the frame. Spans 4 cols
            // because the text block is the only .frame(maxWidth: .infinity) member of
            // collapsedHeader's HStack. growsHorizontally must be true.
            ElementPlacement(
                id: UUID(uuidString: "10cbd000-0000-4000-8000-000000000001")!,
                element: .title, col: 1, row: 0, colSpan: 4,
                layer: .base, visibility: .always, priority: 0),
            // visualizer(height: 16), width = Defaults[.visualizerBarCount] (default
            // 4) * 4 = 16pt. Fixed size, growsHorizontally false. In the source it is
            // vertically centred across the full 60pt header rather than pinned to the
            // title's row; the grid can only anchor it to row 0. Gated by
            // useMusicVisualizer, default true.
            ElementPlacement(
                id: UUID(uuidString: "10cbd000-0000-4000-8000-000000000002")!,
                element: .visualizer, col: 5, row: 0, colSpan: 1,
                layer: .base, visibility: .always, priority: 5),
            // MISMATCH: today this is not an independently positioned element. It is
            // drawn inside MusicTitleMarqueeView's own HStack(spacing: 5), trailing
            // the title text, and the title's usable width is reduced by badgeHeight +
            // badgeHeight*0.7 + spacing (~27pt) — MarqueeTextView.swift:242. Overlay
            // on the trailing title column is the closest grid expression: it consumes
            // no base cell and adds no width, matching the fact that the badge never
            // makes the panel grow. It only renders when
            // musicManager.isCurrentTrackExplicit.
            ElementPlacement(
                id: UUID(uuidString: "10cbd000-0000-4000-8000-000000000003")!,
                element: .explicitBadge, col: 4, row: 0, colSpan: 1,
                layer: .overlay, visibility: .always, priority: 5),
            // .system(size: 10, weight: .regular), lineLimit(1), sitting 1pt under the
            // title inside a 30pt-tall block. Tinted from album art when
            // playerColorTinting is on, else .gray.
            ElementPlacement(
                id: UUID(uuidString: "10cbd000-0000-4000-8000-000000000004")!,
                element: .artist, col: 1, row: 1, colSpan: 4,
                layer: .base, visibility: .always, priority: 2),
            // Direct match, not an approximation: MusicSliderView.inlineContent draws
            // a leading label at .frame(width: 36, alignment: .leading), font
            // .system(size: 11, weight: .medium).monospacedDigit().
            ElementPlacement(
                id: UUID(uuidString: "10cbd000-0000-4000-8000-000000000005")!,
                element: .timeElapsed, col: 0, row: 2, colSpan: 1,
                layer: .base, visibility: .always, priority: 4),
            // MusicSliderView with labelLayout .inline, restingTrackHeight 7 /
            // draggingTrackHeight 11; the row must reserve max(7, 11) = 11 so dragging
            // does not reflow the panel. Sits under .padding(.top, 4) on top of the
            // VStack's 12pt spacing. growsHorizontally true. Live streams swap the
            // track for LiveStreamProgressIndicator at the same height.
            ElementPlacement(
                id: UUID(uuidString: "10cbd000-0000-4000-8000-000000000006")!,
                element: .progressBar, col: 1, row: 2, colSpan: 4,
                layer: .base, visibility: .always, priority: 1),
            // trailingLabel is hard-coded .remaining on this surface, so the label is
            // '-m:ss' at .frame(width: 42, alignment: .trailing). 42 > 36 because of
            // the minus sign. There is no trackTimeToggle equivalent here — the panel
            // offers no way to switch this to total duration, so that element is
            // omitted from the default.
            ElementPlacement(
                id: UUID(uuidString: "10cbd000-0000-4000-8000-000000000007")!,
                element: .timeRemaining, col: 5, row: 2, colSpan: 1,
                layer: .base, visibility: .always, priority: 4),
            // Slot 1 of MusicControlButton.defaultLayout. 32x32 frame, 18pt icon, and
            // when isShuffled it tints to the brand accent and takes a 0.22-opacity
            // background pill. Hidden entirely when showShuffleAndRepeat is off
            // (fallbackSlots), which is why it drops before the core transport.
            ElementPlacement(
                id: UUID(uuidString: "10cbd000-0000-4000-8000-000000000008")!,
                element: .shuffle, col: 0, row: 3, colSpan: 1,
                layer: .base, visibility: .always, priority: 3),
            // Slot 2, MusicControlButton.trackBackward: 'backward.fill', 32x32, 18pt
            // icon, nudge(-9) press interaction collapsed. Priority 0 because
            // minimalLayout keeps it when everything optional is stripped.
            ElementPlacement(
                id: UUID(uuidString: "10cbd000-0000-4000-8000-000000000009")!,
                element: .previous, col: 1, row: 3, colSpan: 1,
                layer: .base, visibility: .always, priority: 0),
            // Centre slot. 54x54 collapsed against 32x32 for its neighbours, so it
            // takes 2 of the 6 columns to keep that 1.69x ratio. HoverButton with
            // scale .large, icon swaps pause.fill/play.fill.
            ElementPlacement(
                id: UUID(uuidString: "10cbd000-0000-4000-8000-000000000010")!,
                element: .playPause, col: 2, row: 3, colSpan: 2,
                layer: .base, visibility: .always, priority: 0),
            // Slot 4, MusicControlButton.trackForward: 'forward.fill', 32x32, 18pt
            // icon, nudge(+9).
            ElementPlacement(
                id: UUID(uuidString: "10cbd000-0000-4000-8000-000000000011")!,
                element: .next, col: 4, row: 3, colSpan: 1,
                layer: .base, visibility: .always, priority: 0),
            // Slot 5. Icon varies with the mode (repeat / repeat.1), active tint plus
            // 0.22 background when mode != .off. Same showShuffleAndRepeat gate as
            // shuffle, hence the same drop priority.
            ElementPlacement(
                id: UUID(uuidString: "10cbd000-0000-4000-8000-000000000012")!,
                element: .repeatMode, col: 5, row: 3, colSpan: 1,
                layer: .base, visibility: .always, priority: 3),
        ])

    /// `LockScreenImmersivePlayer`: big artwork on the left, synced lyrics on
    /// the right, title and artist across the bottom, transport under that.
    ///
    /// Twelve columns because this is the only surface wide enough to want a
    /// real split, and six-and-six matches the source's own
    /// `artSide = min(height * 0.62, hasLyrics ? width * 0.42 : width * 0.6)`.
    /// Dropping `lyrics` from this layout is what "disable lyrics to make the
    /// album cover front and centre" does: the artwork keeps its span, and the
    /// surface centres it because nothing else occupies row 0.
    ///
    /// No progress bar or times: the source draws none.
    /// Two halves, which is what the user asked for and what `rowSpan` was
    /// added to express.
    ///
    /// LEFT  (cols 0-5):  artwork, then title, artist and the transport row
    ///                    directly beneath it.
    /// RIGHT (cols 6-11): lyrics, spanning all four rows.
    ///
    /// The previous version put artwork and lyrics side by side in row 0 and
    /// then ran title, artist and transport across all twelve columns UNDER
    /// both of them — so the lyrics column was one row tall with a full-width
    /// text block cutting across beneath it. That is what "the lyrics look
    /// really wonky" describes, and no arrangement of one-row elements could
    /// fix it.
    ///
    /// The artwork is a COVER here, not a vinyl: this surface is a reading
    /// view, and a spinning record next to scrolling lyrics is two things
    /// competing for the eye.
    public static let defaultLockFull = SurfaceLayout(
        geometry: GridGeometry(columns: 12, contentScale: 1.6, centersContent: true),
        placements: [
            // Square, so a 6-column span is also its height — it sets how tall
            // the left half is, and rows 0-2 share that.
            ElementPlacement(
                id: UUID(uuidString: "10cfd000-0000-4000-8000-000000000000")!,
                element: .artwork, col: 0, row: 0, colSpan: 6, rowSpan: 3,
                layer: .base, visibility: .always, priority: 0,
                artworkStyle: ArtworkStyle(
                    kind: .cover, showsStylus: false, showsProgressRing: false)),
            // Spans every row, so it is a genuine right-hand column rather than
            // a single line stranded at the top.
            ElementPlacement(
                id: UUID(uuidString: "10cfd001-0000-4000-8000-000000000000")!,
                element: .lyrics, col: 6, row: 0, colSpan: 6, rowSpan: 5,
                layer: .base, visibility: .always, priority: 2),
            ElementPlacement(
                id: UUID(uuidString: "10cfd002-0000-4000-8000-000000000000")!,
                element: .title, col: 0, row: 3, colSpan: 6,
                layer: .base, visibility: .always, priority: 1),
            ElementPlacement(
                id: UUID(uuidString: "10cfd003-0000-4000-8000-000000000000")!,
                element: .artist, col: 0, row: 4, colSpan: 6,
                layer: .base, visibility: .always, priority: 3),
            // The progress bar sits under the text, still on the left half, so
            // the two columns stay visually separate.
            ElementPlacement(
                id: UUID(uuidString: "10cfd007-0000-4000-8000-000000000000")!,
                element: .progressBar, col: 0, row: 5, colSpan: 6,
                layer: .base, visibility: .always, priority: 2),
            // Transport directly under the artwork and its text, centred in the
            // left half: cols 1-5 of 0-5.
            ElementPlacement(
                id: UUID(uuidString: "10cfd004-0000-4000-8000-000000000000")!,
                element: .previous, col: 1, row: 6, colSpan: 1,
                layer: .base, visibility: .always, priority: 4),
            ElementPlacement(
                id: UUID(uuidString: "10cfd005-0000-4000-8000-000000000000")!,
                element: .playPause, col: 2, row: 6, colSpan: 2,
                layer: .base, visibility: .always, priority: 0),
            ElementPlacement(
                id: UUID(uuidString: "10cfd006-0000-4000-8000-000000000000")!,
                element: .next, col: 4, row: 6, colSpan: 1,
                layer: .base, visibility: .always, priority: 4),
        ])

    public static let defaultLauncher = SurfaceLayout(
        geometry: GridGeometry(columns: 4, contentScale: 0.82),
        placements: [
            // The record: 38x38 ZStack — black circle at 0.85, album art 26x26 clipped
            // to a circle, 5pt spindle dot. Style .vinyl, not .cover. rowSpan 2 in
            // metrics so it stands beside both text rows (18 + 2 gutter + 18 = 38).
            // Because it spans row 1, requiredHeight must count its overhang even when
            // row 1's own base element is dropped.
            ElementPlacement(
                id: UUID(uuidString: "1a0cbe00-0000-4000-8000-000000000000")!,
                element: .artwork, col: 0, row: 0, colSpan: 1,
                layer: .base, visibility: .always, priority: 0, artworkStyle: .cover),
            // music.songTitle, .system(size: 12, weight: .medium), lineLimit 1,
            // leading. colSpan 3 reconstructs the source's .frame(maxWidth: 140).
            // growsHorizontally; minSpan 2 — below that a truncating 12pt label says
            // nothing.
            ElementPlacement(
                id: UUID(uuidString: "1a0cbe00-0000-4000-8000-000000000001")!,
                element: .title, col: 1, row: 0, colSpan: 3,
                layer: .base, visibility: .always, priority: 0),
            // music.artistName, .system(size: 11), .secondary, lineLimit 1. Today's
            // launcher card shows artist ONLY — unlike VinylWidgetView, which joins
            // artist and album into one 'artist – album' subtitle. So `album` is
            // genuinely absent here, not merged; it is not in this default.
            ElementPlacement(
                id: UUID(uuidString: "1a0cbe00-0000-4000-8000-000000000002")!,
                element: .artist, col: 1, row: 1, colSpan: 3,
                layer: .base, visibility: .always, priority: 2),
            // No equivalent in the source — this is the added transport.
            // backward.end.fill at width*0.062 = 13.4pt on the 216pt card. Overlays
            // the artist line, which cross-fades out on hover. Secondary transport, so
            // first to drop.
            ElementPlacement(
                id: UUID(uuidString: "1a0cbe00-0000-4000-8000-000000000003")!,
                element: .previous, col: 1, row: 1, colSpan: 1,
                layer: .overlay, visibility: .onHover, priority: 3),
            // play.fill / pause.fill at width*0.082 = 17.7pt, which fits the ~18pt
            // row-1 band exactly — this is why the transport can be an overlay and the
            // card never grows. Must consume its own tap or WidgetCard's onTapGesture
            // fires and dismisses the launcher.
            ElementPlacement(
                id: UUID(uuidString: "1a0cbe00-0000-4000-8000-000000000004")!,
                element: .playPause, col: 2, row: 1, colSpan: 1,
                layer: .overlay, visibility: .onHover, priority: 0),
            // forward.end.fill at width*0.062 = 13.4pt. Centre of cell 3. Same
            // tap-consumption requirement as playPause.
            ElementPlacement(
                id: UUID(uuidString: "1a0cbe00-0000-4000-8000-000000000005")!,
                element: .next, col: 3, row: 1, colSpan: 1,
                layer: .overlay, visibility: .onHover, priority: 3),
        ])

}

// MARK: - Presets

/// Named starting points, offered per surface in the layout editor.
///
/// Distinct from `PlayerLayouts.defaults`, which is what a first launch gets
/// and what Reset restores. A preset is a deliberate choice the user makes;
/// applying one is a normal, undoable edit.
public struct LayoutPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let layout: SurfaceLayout

    /// What is on offer for a given surface. The shipped default is always
    /// first, so "put it back the way it was" is never more than one click away
    /// even after experimenting.
    public static func all(for surface: PlayerSurface) -> [LayoutPreset] {
        var presets: [LayoutPreset] = [
            LayoutPreset(
                id: "default", name: "As shipped",
                detail: "The layout Cadence starts with.",
                layout: PlayerLayouts.defaults[surface])
        ]
        switch surface {
        case .desktop:
            presets.append(contentsOf: [.compactDesktop, .artworkOnly, .fullDesktop])
        case .lockWidget:
            presets.append(contentsOf: [.compactDesktop])
        case .lockFull, .desktopFull:
            // Both full-screen surfaces are two-column reading views; a
            // "compact" variant of one is just the small widget.
            break
        case .launcher:
            break
        }
        return presets
    }

    /// Artwork, title, transport. Nothing else — the smallest thing that is
    /// still a player.
    static let compactDesktop = LayoutPreset(
        id: "compact", name: "Compact",
        detail: "Artwork, title and transport only.",
        layout: SurfaceLayout(
            geometry: GridGeometry(columns: 6),
            placements: [
                ElementPlacement(
                    element: .artwork, col: 0, row: 0, colSpan: 2, rowSpan: 2,
                    priority: 0, artworkStyle: .vinyl),
                ElementPlacement(element: .title, col: 2, row: 0, colSpan: 4, priority: 1),
                ElementPlacement(element: .artist, col: 2, row: 1, colSpan: 4, priority: 2),
                ElementPlacement(element: .previous, col: 2, row: 2, colSpan: 1, priority: 3),
                ElementPlacement(element: .playPause, col: 3, row: 2, colSpan: 2, priority: 0),
                ElementPlacement(element: .next, col: 5, row: 2, colSpan: 1, priority: 3),
            ]))

    /// Just the record, with the transport revealed on hover as an overlay so
    /// the card never changes size.
    static let artworkOnly = LayoutPreset(
        id: "artwork", name: "Artwork only",
        detail: "The record alone. Controls appear over it on hover.",
        layout: SurfaceLayout(
            geometry: GridGeometry(columns: 6),
            placements: [
                ElementPlacement(
                    element: .artwork, col: 0, row: 0, colSpan: 6, rowSpan: 4,
                    priority: 0,
                    artworkStyle: ArtworkStyle(
                        kind: .vinyl, showsStylus: true, showsProgressRing: true)),
                ElementPlacement(
                    element: .previous, col: 1, row: 3, colSpan: 1, layer: .overlay,
                    visibility: .onHover, priority: 4),
                ElementPlacement(
                    element: .playPause, col: 2, row: 3, colSpan: 2, layer: .overlay,
                    visibility: .onHover, priority: 0),
                ElementPlacement(
                    element: .next, col: 4, row: 3, colSpan: 1, layer: .overlay,
                    visibility: .onHover, priority: 4),
            ]))

    /// Everything worth having on a desktop card, priorities ordered so it
    /// degrades sensibly as it shrinks.
    static let fullDesktop = LayoutPreset(
        id: "full", name: "Everything",
        detail: "Artwork, text, transport, progress, times, shuffle and repeat.",
        layout: SurfaceLayout(
            geometry: GridGeometry(columns: 6),
            placements: [
                ElementPlacement(
                    element: .artwork, col: 0, row: 0, colSpan: 2, rowSpan: 2,
                    priority: 0, artworkStyle: .vinyl),
                ElementPlacement(element: .title, col: 2, row: 0, colSpan: 4, priority: 1),
                ElementPlacement(element: .artist, col: 2, row: 1, colSpan: 4, priority: 3),
                ElementPlacement(element: .album, col: 0, row: 2, colSpan: 6, priority: 6),
                ElementPlacement(element: .progressBar, col: 0, row: 3, colSpan: 6, priority: 2),
                ElementPlacement(element: .timeElapsed, col: 0, row: 4, colSpan: 1, priority: 5),
                ElementPlacement(element: .shuffle, col: 1, row: 4, colSpan: 1, priority: 7),
                ElementPlacement(element: .previous, col: 2, row: 4, colSpan: 1, priority: 4),
                ElementPlacement(element: .playPause, col: 3, row: 4, colSpan: 1, priority: 0),
                ElementPlacement(element: .next, col: 4, row: 4, colSpan: 1, priority: 4),
                ElementPlacement(element: .timeRemaining, col: 5, row: 4, colSpan: 1, priority: 5),
            ]))
}

// MARK: - Migration

extension PlayerLayouts {
    /// The latest migration number. Bump when a shipped default is corrected in
    /// a way existing installs must receive.
    static let currentMigration = 1

    /// Bring a stored set of layouts up to date, once.
    ///
    /// Migration 1 fixes two defaults that were wrong rather than merely
    /// different, and which a stored layout would otherwise mask forever:
    ///
    /// - `lockFull` put artwork and lyrics side by side in row 0 and then ran
    ///   title, artist and transport across all twelve columns beneath BOTH, so
    ///   the lyrics column was one row tall with a text block cutting through
    ///   it. It is rebuilt around `rowSpan` as two halves.
    /// - `lockWidget` never set `centersContent`, so its arrangement sat against
    ///   the leading edge with all the slack on one side.
    ///
    /// The widget keeps every placement the user made — only the geometry flag
    /// changes. The full-screen layout is replaced outright, because it is the
    /// surface whose arrangement was the defect.
    /// Pure: the stored version comes IN and the caller writes the new one back.
    /// `Sources/Layout` deliberately imports neither SwiftUI nor Defaults, which
    /// is what lets the shell harness compile it directly — putting a
    /// `Defaults` read here breaks the whole test suite's build.
    static func migrated(_ stored: PlayerLayouts, from version: Int) -> PlayerLayouts {
        guard version < currentMigration else { return stored }
        var updated = stored
        updated.lockFull = .defaultLockFull
        updated.lockWidget.geometry.centersContent = true
        return updated
    }
}
