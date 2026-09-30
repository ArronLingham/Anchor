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

/// Draws one surface from its `SurfaceLayout`.
///
/// This is the single renderer. Anchor has the same `switch` copy-pasted into
/// `NotchHomeView`, `MinimalisticMusicPlayerView` and `LockScreenMusicPanel`,
/// and hardcoded outright in `MusicControlOverlay` and `VinylWidgetView` — five
/// places to edit to add one control. Here the *style* and the *data* are
/// injected and the switch is written once.
struct PlayerSurfaceView: View {
    let layout: SurfaceLayout
    let style: SurfaceStyle
    var hovering: Bool = false
    /// Frozen data for the settings preview. `nil` means live playback.
    var snapshot: PlayerSnapshot?
    /// What a single click on the artwork does. Defaults to nothing, so a
    /// surface with no full-screen view of its own is unaffected.
    var onExpand: () -> Void = {}

    var body: some View {
        // Two bodies, and the split is the point: the live one observes
        // `MusicManager` and the frozen one does not. A single view holding an
        // `@ObservedObject` observes it unconditionally, so the settings preview
        // — which is bound to a fixed sample — re-rendered on every playback
        // publish, of which there are 29 kinds, for a track it does not show.
        if let snapshot {
            SurfaceBody(
                layout: layout, style: style, hovering: hovering,
                data: snapshot, actions: .inert, isLive: false)
        } else {
            LiveSurfaceBody(
                layout: layout, style: style, hovering: hovering, onExpand: onExpand)
        }
    }
}

/// The live surface. Observes playback; everything else is `SurfaceBody`.
private struct LiveSurfaceBody: View {
    let layout: SurfaceLayout
    let style: SurfaceStyle
    let hovering: Bool
    /// What clicking the artwork does. Supplied by the host, because only the
    /// host knows whether it owns a full-screen view.
    let onExpand: () -> Void

    @ObservedObject private var music = MusicManager.shared

    var body: some View {
        var actions = PlayerActions.live(music)
        actions.expand = onExpand
        return SurfaceBody(
            layout: layout, style: style, hovering: hovering,
            data: .live(music), actions: actions, isLive: true)
    }
}

private struct SurfaceBody: View {
    let layout: SurfaceLayout
    let style: SurfaceStyle
    let hovering: Bool
    let data: PlayerSnapshot
    let actions: PlayerActions
    let isLive: Bool

    var body: some View {
        GeometryReader { geo in
            let resolved = GridSolver.solve(
                layout: layout, available: geo.size, hovering: hovering)
            ZStack(alignment: .topLeading) {
                // `elements` arrives base-first then overlay, which is the draw
                // order — the renderer needs no z-index of its own.
                ForEach(resolved.elements, id: \.placement.id) { element in
                    PlayerElementView(
                        placement: element.placement, style: style, data: data,
                        actions: actions, isLive: isLive
                    )
                    .frame(width: element.frame.width, height: element.frame.height)
                    .offset(x: element.frame.minX, y: element.frame.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

/// Per-surface appearance. The desktop card, the lock-screen glass panel and the
/// launcher card want the same elements at different weights.
struct SurfaceStyle {
    var ink: Color
    var subtleInk: Color
    var accent: Color
    /// What the progress bar and ring are drawn in.
    ///
    /// `sliderColor` was a live setting with three options whose only reader in
    /// the whole tree was `RealTimeWaveformScrubberView` — a view that is only
    /// on screen when the real-time waveform is enabled AND a visualiser is
    /// placed. The ordinary progress bar hardcoded `ink`, so the picker did
    /// nothing for the element it names. Resolved once here rather than at each
    /// call site so the bar and the ring can never disagree.
    var progress: Color
    /// Multiplies every font size. Comes from the layout's own
    /// `GridGeometry.contentScale`, which also drives the row heights — two
    /// separate constants is how a 24pt title ended up in a 20pt row.
    var textScale: CGFloat

    /// `sliderColor` is a PARAMETER, not a `Defaults` read inside this function.
    ///
    /// A bare `Defaults[...]` here would be read during body evaluation and
    /// therefore never observed, so changing the picker would not redraw
    /// anything until some unrelated publish happened to refresh the view —
    /// which looks exactly like "progress bar colour doesn't change". Every
    /// caller holds it in an `@Default` property and passes it in.
    static func forSurface(
        _ surface: PlayerSurface, albumColor: NSColor, tinted: Bool, scale: CGFloat,
        sliderColor: SliderColorEnum = .white, accentColor: Color = .blue
    ) -> SurfaceStyle {
        let ink: Color =
            tinted
            ? (SurfaceStyle.isLight(SurfaceStyle.muted(albumColor))
                ? .black.opacity(0.82) : .white.opacity(0.92))
            : .white
        let progress: Color
        switch sliderColor {
        case .white: progress = ink
        case .albumArt: progress = Color(nsColor: SurfaceStyle.vivid(albumColor))
        case .accent: progress = accentColor
        }
        return SurfaceStyle(
            ink: ink, subtleInk: ink.opacity(0.55), accent: Color(nsColor: albumColor),
            progress: progress, textScale: scale)
    }

    /// The album colour with enough saturation left to read as a colour.
    ///
    /// `muted` exists to stop a background shouting; using it for the bar as
    /// well would make "Match album art" almost indistinguishable from white on
    /// a tinted card, which is the complaint that "progress bar colour doesn't
    /// change" partly describes.
    static func vivid(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            hue: hue, saturation: max(saturation, 0.55),
            brightness: max(brightness, 0.85), alpha: alpha)
    }

    /// Clamp saturation and brightness so an album's colour is a background
    /// rather than a shout. Lifted from `VinylWidgetView`, which is where the
    /// numbers were arrived at.
    static func muted(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return NSColor(white: 0.16, alpha: 1) }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            hue: hue, saturation: min(saturation, 0.22),
            brightness: max(0.58, min(brightness, 0.80)), alpha: 1)
    }

    /// Rec. 709 luma — matches how the eye weights the channels, so a saturated
    /// yellow correctly counts as light and a blue does not.
    static func isLight(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let luma =
            0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luma > 0.45
    }
}

// MARK: - One element

struct PlayerElementView: View {
    /// Schedules are anchored here, not at `.now`.
    ///
    /// `TimelineView(.periodic(from: .now, by: 0.25))` re-anchors every time the
    /// view is rebuilt, so a surface that re-renders for any other reason keeps
    /// restarting its own clock and the cadence never settles. A fixed epoch
    /// gives every instance the same phase and lets the system coalesce them.
    static let scheduleAnchor = Date(timeIntervalSince1970: 0)

    let placement: ElementPlacement
    let style: SurfaceStyle
    let data: PlayerSnapshot
    let actions: PlayerActions
    var isLive: Bool = true

    @State private var showingRemaining = false
    /// Non-nil only while the scrubber is being dragged. The bar follows the
    /// pointer from this, because `data.position` keeps advancing from the
    /// controller's last report and would fight the drag.
    @State private var scrubFraction: CGFloat?

    var body: some View {
        switch placement.element {
        case .artwork: artwork
        // With nothing playing the title says so and the other two say nothing.
        // Three lines of "Nothing playing" would be worse than one, and the
        // alternative — leaving all three blank — leaves a card that looks
        // broken rather than idle.
        case .title:
            text(
                data.hasTrack ? data.title : String(localized: "Nothing playing"),
                size: 15, weight: .semibold, subtle: !data.hasTrack)
        case .artist: text(data.hasTrack ? data.artist : "", size: 12, weight: .regular, subtle: true)
        case .album: text(data.hasTrack ? data.album : "", size: 12, weight: .regular, subtle: true)

        case .playPause:
            button(
                data.isPlaying ? "pause.fill" : "play.fill", scale: 1.25, action: actions.playPause)
        case .next: button("forward.end.fill", action: actions.next)
        case .previous: button("backward.end.fill", action: actions.previous)
        case .seekForward: button("goforward.10") { actions.seekBy(10) }
        case .seekBackward: button("gobackward.10") { actions.seekBy(-10) }
        case .shuffle:
            button("shuffle", active: data.isShuffled, action: actions.toggleShuffle)
        case .repeatMode:
            button(
                data.repeatMode == .one ? "repeat.1" : "repeat",
                active: data.repeatMode != .off, action: actions.toggleRepeat)

        case .progressBar: progressBar
        case .timeElapsed: timeLabel { Self.timestamp($0) }
        case .timeRemaining:
            timeLabel { "-" + Self.timestamp(max(0, self.data.duration - $0)) }
        case .trackTimeToggle: trackTimeToggle

        case .lyrics: lyrics
        case .outputDevice: OutputDeviceElement(style: style, isLive: isLive)
        case .airPlay: AirPlayElement(style: style, isLive: isLive)
        case .volumeSlider: VolumeElement(style: style, isLive: isLive)
        case .visualizer: visualizer

        case .appIcon: appIcon
        case .explicitBadge: explicitBadge
        case .clock: clock
        case .timer: PlayerTimerElement(style: style, isLive: isLive)
        }
    }

    /// `lyrics` is two things, and which one you get follows the room it was
    /// given — which is what a grid is for. One cell is a toggle button, as it
    /// is in a transport row. Three or more is the scrolling panel, as it is on
    /// the full-screen lock player, where the layout hands it half the screen.
    ///
    /// Before this, a span-6 placement rendered a 13pt speech-bubble glyph in
    /// the middle of an empty half-screen.
    @ViewBuilder private var lyrics: some View {
        // Threshold was 3, so on any surface where the user gave lyrics a
        // narrow slot they silently got a TOGGLE BUTTON instead of words —
        // which is why lyrics "work on the full-screen lock screen but not on
        // anything else". Two columns is enough for a line of text; only a
        // genuinely 1-column slot falls back to the button, and that fallback
        // is now the documented behaviour rather than a surprise.
        if placement.colSpan >= 2 {
            if data.hasSyncedLyrics {
                SyncedLyricsList(
                    currentSize: 15 * style.textScale, otherSize: 12 * style.textScale,
                    lineSpacing: 10 * style.textScale, fitted: true, fittedCapacity: 5,
                    linesBefore: 1
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(data.currentLyric)
                    .font(.system(size: 15 * style.textScale, weight: .medium))
                    .foregroundStyle(style.subtleInk)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            button("quote.bubble", active: data.showLyrics, action: actions.toggleLyrics)
        }
    }

    // MARK: Artwork

    @ViewBuilder private var artwork: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // The record is inset by the ring's allowance whether or not the
            // ring is drawn, so turning it on does not resize the record.
            let discSide = max(1, side - artworkInset(side: side))
            ZStack {
                switch placement.artworkStyle.kind {
                case .vinyl:
                    // labelFraction 0.46 matches what VinylWidgetView passes;
                    // the view's own default of 0.38 is for a smaller record.
                    VinylRecordRepresentable(
                        artwork: data.hasTrack ? data.artwork : nil,
                        isPlaying: data.isPlaying, labelFraction: 0.46)
                        .frame(width: discSide, height: discSide)
                    if placement.artworkStyle.showsStylus { tonearm(side: side) }
                case .cover:
                    if data.hasTrack {
                        Image(nsImage: data.artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: side, height: side)
                            .clipShape(
                                RoundedRectangle(cornerRadius: side * 0.06, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: side * 0.06, style: .continuous)
                            .fill(style.ink.opacity(0.08))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: side * 0.3, weight: .light))
                                    .foregroundStyle(style.ink.opacity(0.25)))
                            .frame(width: side, height: side)
                    }
                }
                if placement.artworkStyle.showsProgressRing { progressRing(side: side) }
            }
            .frame(width: side, height: side)
            .frame(width: geo.size.width, height: geo.size.height)
            // The record is itself the largest play/pause target, which is how
            // the vinyl widget already behaves.
            .contentShape(
                placement.artworkStyle.kind == .vinyl ? AnyShape(Circle()) : AnyShape(Rectangle())
            )
            // A SINGLE click opens the full-screen view where there is one.
            // The artwork used to be the play/pause target — deliberately, as
            // the largest one — but a click that both expands and toggles
            // playback cannot be built, so play/pause is the transport button's
            // job now and every default layout has one.
            .onTapGesture(perform: actions.expand)
        }
    }

    /// The ring reported as "appears around the vinyl and expands in size".
    ///
    /// Both halves of that were real, and neither was an animation:
    ///
    /// 1. There was no TRACK circle — only the trimmed progress arc. At 0% that
    ///    is a single round dot at twelve o'clock which sweeps clockwise and
    ///    grows into a full circle as the song plays. A ring that appears and
    ///    expands, literally. `VinylWidgetView`, where this was ported from,
    ///    drew the unfilled backing circle first.
    /// 2. It was framed at `side * 1.045`, larger than the `side`-square box the
    ///    artwork is clipped to, so it overflowed its own cell.
    ///
    /// Now the disc is inset by the ring's own width and the ring sits in the
    /// annulus that frees up, entirely inside `side`.
    private func progressRing(side: CGFloat) -> some View {
        let lineWidth = max(2, side * 0.028)
        // Inset by half a stroke so the stroke's outer edge lands on the box
        // edge rather than straddling it.
        let diameter = side - lineWidth
        return ZStack {
            Circle()
                .stroke(style.ink.opacity(0.18), lineWidth: lineWidth)
            TimelineView(
                .periodic(from: Self.scheduleAnchor, by: data.isPlaying ? 0.25 : 60)
            ) { context in
                Circle()
                    .trim(from: 0, to: fraction(at: context.date))
                    .stroke(
                        style.progress.opacity(0.9),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// How much smaller the artwork itself is when a ring is drawn around it.
    ///
    /// Constant whether the ring is ON or OFF for `.vinyl`, so toggling it does
    /// not resize the record — the ring appears in space that was already
    /// reserved, instead of the record jumping.
    private func artworkInset(side: CGFloat) -> CGFloat {
        placement.artworkStyle.kind == .vinyl ? max(2, side * 0.028) * 2.2 : 0
    }

    /// The tonearm, ported from `VinylWidgetView`. It lives here rather than in
    /// `VinylRecordView` because that view is CALayer-based and deliberately
    /// rotates everything it owns — an arm inside it would spin with the record.
    private func tonearm(side: CGFloat) -> some View {
        let pivot = side * 0.16
        let armLength = side * 0.50
        return ZStack(alignment: .top) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.95), Color(white: 0.62)],
                        center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: pivot * 0.7)
                )
                .frame(width: pivot, height: pivot)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color(white: 0.28))
                    .frame(width: max(2.5, side * 0.019), height: armLength)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(white: 0.22))
                    .frame(width: side * 0.07, height: side * 0.072)
            }
            .offset(y: pivot * 0.45)
            .rotationEffect(.degrees(data.isPlaying ? 32 : 12), anchor: .top)
            // Asymmetric on purpose. The record does not coast to a halt —
            // `VinylRecordView.stopSpin()` removes the CABasicAnimation and
            // writes the frozen angle in the same turn — so a 0.75s spring
            // lifting the arm read as the arm reacting late to a stop that had
            // already happened. Lifting is quick and barely bouncy; cueing back
            // down keeps the slower settle, which is how a real arm behaves and
            // is the direction where the delay looks deliberate.
            .animation(
                data.isPlaying
                    ? .spring(response: 0.55, dampingFraction: 0.78)
                    : .spring(response: 0.22, dampingFraction: 0.9),
                value: data.isPlaying)
        }
        .frame(width: pivot, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }

    // MARK: Text

    private func text(_ value: String, size: CGFloat, weight: Font.Weight, subtle: Bool = false)
        -> some View
    {
        Text(value)
            .font(.system(size: size * style.textScale, weight: weight))
            .foregroundStyle(subtle ? style.subtleInk : style.ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Buttons

    private func button(
        _ symbol: String, scale: CGFloat = 1, active: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13 * scale * style.textScale, weight: .medium))
                .foregroundStyle(active ? style.accent : style.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Progress and time

    /// Interpolated locally rather than driven by a publish per frame.
    ///
    /// `MusicManager` is event-driven: `elapsedTime` is assigned when the
    /// controller reports a time change, not on a tick. The snapshot's
    /// `position` projects forward from that using `timestampDate` and
    /// `playbackRate`, so a `TimelineView` animates smoothly while the manager
    /// stays quiet.
    private func fraction(at date: Date) -> CGFloat {
        guard data.hasTrack, data.duration > 0, data.duration.isFinite else { return 0 }
        return min(max(data.position(date) / data.duration, 0), 1)
    }

    private var progressBar: some View {
        TimelineView(.periodic(from: Self.scheduleAnchor, by: data.isPlaying ? 0.25 : 60)) { context in
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(style.ink.opacity(0.22))
                    Capsule().fill(style.progress.opacity(0.9))
                        .frame(
                            width: geo.size.width
                                * (scrubFraction ?? fraction(at: context.date)))
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                // `minimumDistance: 0` fires `onChanged` on the initial press,
                // so this subsumes tap-to-seek — a separate `onTapGesture`
                // alongside it would compete for the same events and make both
                // unreliable. Dragging never reached SwiftUI at all before,
                // because the panel had `isMovableByWindowBackground` on and
                // AppKit claimed the whole card as drag background.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard data.duration > 0, data.duration.isFinite else { return }
                            scrubFraction = min(
                                max(value.location.x / max(1, geo.size.width), 0), 1)
                        }
                        .onEnded { value in
                            defer { scrubFraction = nil }
                            guard data.duration > 0, data.duration.isFinite else { return }
                            let f = min(max(value.location.x / max(1, geo.size.width), 0), 1)
                            // Committed once, on release. `MusicManager.seek`
                            // spawns a Task per call, so seeking per mouse-move
                            // would be a controller round trip every frame.
                            actions.seekTo(data.duration * f)
                        })
            }
        }
    }

    private func timeLabel(_ format: @escaping (TimeInterval) -> String) -> some View {
        TimelineView(.periodic(from: Self.scheduleAnchor, by: data.isPlaying ? 0.5 : 60)) { context in
            Text(data.hasTrack ? format(data.position(context.date)) : "--:--")
                .font(.system(size: 10 * style.textScale, weight: .medium).monospacedDigit())
                .foregroundStyle(style.subtleInk)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var trackTimeToggle: some View {
        Button {
            showingRemaining.toggle()
        } label: {
            TimelineView(.periodic(from: Self.scheduleAnchor, by: data.isPlaying ? 0.5 : 60)) { context in
                let position = data.position(context.date)
                Text(
                    showingRemaining
                        ? "-" + Self.timestamp(max(0, data.duration - position))
                        : Self.timestamp(position)
                )
                .font(.system(size: 10 * style.textScale, weight: .medium).monospacedDigit())
                .foregroundStyle(style.subtleInk)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    /// A live stream reports a NaN duration as a matter of course, and
    /// `Int(someDouble)` **traps** on NaN — not an exception, a hard crash.
    /// Anchor took a SIGTRAP here while simply drawing elapsed time over live
    /// content, in two separate files with the same helper.
    static func timestamp(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Extras

    private var visualizer: some View {
        // `AudioVisualizerView` takes a Binding because Anchor's callers own the
        // state. Nothing here writes it back, so a constant is honest — and it
        // matters that this view is only constructed when the element is placed:
        // the real-time variant acquires the CoreAudio process tap, which is
        // reference-counted and must not be held by a surface nobody is looking
        // at. That single mistake was worth 12x Anchor's idle CPU.
        AudioVisualizerView(isPlaying: .constant(data.isPlaying))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var appIcon: some View {
        if let bundleID = data.bundleIdentifier, let icon = AppIconAsNSImage(for: bundleID) {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var explicitBadge: some View {
        if data.isExplicit {
            Image(systemName: "e.square.fill")
                .font(.system(size: 10 * style.textScale))
                .foregroundStyle(style.subtleInk)
        } else {
            Color.clear
        }
    }

    /// The system schedules this; nothing here polls. A minute-granularity
    /// `TimelineView` wakes once a minute and not otherwise.
    private var clock: some View {
        TimelineView(.periodic(from: Self.scheduleAnchor, by: 60)) { context in
            Text(context.date, style: .time)
                .font(.system(size: 13 * style.textScale, weight: .medium).monospacedDigit())
                .foregroundStyle(style.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Type-erased shape so `contentShape` can pick between a circle and a rect.
///
/// `@unchecked Sendable`: the stored closure captures only the shape it was
/// built from, and every shape used here is a value type — but a closure cannot
/// carry that proof. The alternative is an enum of every shape in use, which is
/// worse for no gain.
struct AnyShape: Shape, @unchecked Sendable {
    private let make: (CGRect) -> Path
    init<S: Shape>(_ shape: S) { make = { shape.path(in: $0) } }
    func path(in rect: CGRect) -> Path { make(rect) }
}
