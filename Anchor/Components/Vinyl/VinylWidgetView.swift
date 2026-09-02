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

/// How playback position is drawn on the vinyl widget.
enum VinylProgressStyle: String, Codable, CaseIterable, Defaults.Serializable {
    /// A ring around the record.
    case ring
    /// A line under the transport, with elapsed and remaining times.
    case bar

    var label: String {
        switch self {
        case .ring: return String(localized: "Ring around the record")
        case .bar: return String(localized: "Bar with times")
        }
    }
}

/// Bridges the CALayer record into SwiftUI.
///
/// Only three things cross the boundary — the artwork, whether it is turning,
/// and the label size — so the record never rebuilds its layers for a state
/// change SwiftUI made elsewhere.
struct VinylRecordRepresentable: NSViewRepresentable {
    let artwork: NSImage?
    let isPlaying: Bool
    let labelFraction: CGFloat

    func makeNSView(context: Context) -> VinylRecordView {
        let view = VinylRecordView(frame: .zero)
        view.labelFraction = labelFraction
        view.setArtwork(artwork)
        view.setSpinning(isPlaying)
        return view
    }

    func updateNSView(_ view: VinylRecordView, context: Context) {
        view.labelFraction = labelFraction
        view.setArtwork(artwork)
        view.setSpinning(isPlaying)
    }
}

/// The desktop vinyl widget: a card holding the record, the track, transport
/// and playback position.
struct VinylWidgetView: View {
    @ObservedObject private var music = MusicManager.shared

    @Default(.vinylWidgetSize) private var size
    @Default(.vinylOrientation) private var orientation
    @Default(.vinylWindowLevel) private var windowLevel
    @Default(.vinylShowStylus) private var showStylus
    @Default(.vinylProgressStyle) private var progressStyle
    @Default(.vinylShowProgress) private var showProgress
    @Default(.vinylShowTitle) private var showTitle
    @Default(.vinylUseAlbumColor) private var useAlbumColor
    @Default(.vinylBackgroundOpacity) private var backgroundOpacity

    @State private var isHovering = false

    // MARK: - Colour
    //
    // The card takes its colour from the album, but never at full strength:
    // artwork is frequently saturated to the point of being unusable as a
    // background, so the hue is kept and the saturation and brightness are
    // pinned into a narrow band. That is what makes any album produce a card
    // that still reads as one family rather than a random paint chart.

    private var cardColor: Color {
        guard useAlbumColor else { return Color(white: 0.16) }
        return Color(nsColor: Self.muted(music.avgColor))
    }

    private var inkColor: Color {
        guard useAlbumColor else { return .white }
        return Self.isLight(Self.muted(music.avgColor)) ? .black.opacity(0.82) : .white.opacity(0.92)
    }

    private var subtleInk: Color { inkColor.opacity(0.55) }

    private static func muted(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return NSColor(white: 0.16, alpha: 1) }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            hue: hue,
            saturation: min(saturation, 0.22),
            brightness: max(0.58, min(brightness, 0.80)),
            alpha: 1)
    }

    private static func isLight(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        // Rec. 709 luma — matches how the eye weights the channels, so a
        // saturated yellow correctly counts as light and a blue does not.
        let luma = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luma > 0.45
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            // Portrait sizes everything from the card width; landscape sizes it
            // from the height, since there the record is what sets the height
            // and the text column sits beside it.
            let width = orientation == .portrait
                ? geometry.size.width
                : geometry.size.height / 0.52
            let recordSide = orientation == .portrait
                ? width * 0.72
                : geometry.size.height * 0.78

            Group {
                if orientation == .portrait {
                    VStack(spacing: 0) {
                        turntable(width: width, recordSide: recordSide)
                        stack(width: width)
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(spacing: width * 0.05) {
                        turntable(width: width, recordSide: recordSide)
                        VStack(alignment: .leading, spacing: 0) {
                            Spacer(minLength: 0)
                            stack(width: width)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(width * 0.075)
            .frame(width: geometry.size.width, height: geometry.size.height,
                   alignment: orientation == .portrait ? .top : .leading)
            .background(card)
            // Every setting, on the widget itself — the point of a desktop
            // widget is not having to go and find a settings window for it.
            .contextMenu { settingsMenu }
            .overlay(alignment: .topTrailing) { closeButton }
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.35), value: music.avgColor)
        .animation(.easeInOut(duration: 0.25), value: orientation)
    }

    /// Title, transport and progress — the same stack either way round.
    @ViewBuilder
    private func stack(width: CGFloat) -> some View {
        if showTitle {
            trackLabels(width: width)
                .padding(.top, orientation == .portrait ? width * 0.055 : 0)
        }

        transport(width: width)
            .padding(.top, showTitle ? width * 0.05 : (orientation == .portrait ? width * 0.07 : 0))

        if showProgress && progressStyle == .bar {
            progressBar(width: width)
                .padding(.top, width * 0.045)
        }
    }

    /// Closing sends the widget behind everything rather than switching it off.
    ///
    /// Turning it off is a decision that takes a trip to Settings to undo;
    /// dropping it to the desktop layer gets it out of the way and leaves it
    /// where you put it. It only appears on hover, so it is not part of the
    /// card's resting look.
    @ViewBuilder
    private var closeButton: some View {
        if isHovering && windowLevel != .desktop {
            Button {
                windowLevel = .desktop
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(5)
                    .background(Circle().fill(.black.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .padding(8)
            .help("Send behind all windows")
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var settingsMenu: some View {
        Picker("Size", selection: $size) {
            ForEach(VinylWidgetSize.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("Shape", selection: $orientation) {
            ForEach(VinylOrientation.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Picker("Layer", selection: $windowLevel) {
            ForEach(VinylWindowLevel.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Divider()
        Toggle("Show the title", isOn: $showTitle)
        Toggle("Show the progress bar", isOn: $showProgress)
        Toggle("Show the tonearm", isOn: $showStylus)
        Toggle("Tint from the album art", isOn: $useAlbumColor)
        Divider()
        // A menu cannot hold a slider, so the transparency steps are offered as
        // choices. The slider itself lives in Settings for finer control.
        Picker("Background", selection: $backgroundOpacity) {
            Text("Transparent").tag(0.0)
            Text("Faint").tag(0.25)
            Text("Half").tag(0.5)
            Text("Mostly solid").tag(0.75)
            Text("Solid").tag(1.0)
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(cardColor.opacity(max(backgroundOpacity, 0.001) > 0.001 ? 1 : 1))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
    }

    // MARK: - Turntable

    private func turntable(width: CGFloat, recordSide: CGFloat) -> some View {
        ZStack {
            if showProgress && progressStyle == .ring {
                progressRing(side: recordSide + width * 0.045)
            }

            VinylRecordRepresentable(
                artwork: music.albumArt,
                isPlaying: music.isPlaying,
                labelFraction: 0.46)
            .frame(width: recordSide, height: recordSide)
            // The record is the obvious thing to press to stop the music, and
            // it is by far the largest target on the card — the transport's
            // play button is a fraction of its size.
            .contentShape(Circle())
            .onTapGesture { music.playPause() }
            .help(music.isPlaying ? "Pause" : "Play")

            if showStylus {
                tonearm(width: width, recordSide: recordSide)
            }
        }
        .frame(width: recordSide + width * 0.10, height: recordSide)
    }

    /// The tonearm: pivot in the top-right corner, arm swinging down onto the
    /// record while playing and lifting clear when it stops.
    private func tonearm(width: CGFloat, recordSide: CGFloat) -> some View {
        let pivot = width * 0.115
        let armLength = recordSide * 0.50

        return ZStack(alignment: .top) {
            // Pivot housing
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.95), Color(white: 0.62)],
                        center: .init(x: 0.35, y: 0.3),
                        startRadius: 0,
                        endRadius: pivot * 0.7))
                .frame(width: pivot, height: pivot)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)

            // Arm and head, rotating about the pivot
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color(white: 0.28))
                    .frame(width: max(2.5, width * 0.014), height: armLength)

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(white: 0.22))
                    .frame(width: width * 0.05, height: width * 0.052)
            }
            .offset(y: pivot * 0.45)
            .rotationEffect(
                .degrees(music.isPlaying ? 32 : 12),
                anchor: .top)
            .animation(.spring(response: 0.75, dampingFraction: 0.82), value: music.isPlaying)
        }
        .frame(width: pivot, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .offset(x: pivot * 0.15, y: -pivot * 0.25)
        .allowsHitTesting(false)
    }

    private func progressRing(side: CGFloat) -> some View {
        ZStack {
            Circle().strokeBorder(inkColor.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(inkColor.opacity(0.75), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: side, height: side)
    }

    // MARK: - Text and transport

    private func trackLabels(width: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(music.songTitle)
                .font(.system(size: width * 0.062, weight: .semibold))
                .foregroundStyle(inkColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(subtitle)
                .font(.system(size: width * 0.048))
                .foregroundStyle(subtleInk)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
    }

    private var subtitle: String {
        let album = music.album.trimmingCharacters(in: .whitespaces)
        let artist = music.artistName.trimmingCharacters(in: .whitespaces)
        if album.isEmpty || album == artist { return artist }
        return "\(artist) – \(album)"
    }

    private func transport(width: CGFloat) -> some View {
        HStack(spacing: width * 0.10) {
            control("backward.end.fill", size: width * 0.062) { music.previousTrack() }
            control(music.isPlaying ? "pause.fill" : "play.fill", size: width * 0.082) {
                music.playPause()
            }
            control("forward.end.fill", size: width * 0.062) { music.nextTrack() }
        }
        .frame(maxWidth: .infinity)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(inkColor.opacity(isHovering ? 1 : 0.85))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Progress

    private var fraction: Double {
        guard music.songDuration > 0 else { return 0 }
        return min(max(music.elapsedTime / music.songDuration, 0), 1)
    }

    private func progressBar(width: CGFloat) -> some View {
        VStack(spacing: width * 0.018) {
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(inkColor.opacity(0.18))
                        .frame(height: 2.5)
                    Capsule()
                        .fill(inkColor.opacity(0.7))
                        .frame(width: bar.size.width * fraction, height: 2.5)
                }
                .frame(height: bar.size.height, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard music.songDuration > 0, bar.size.width > 0 else { return }
                    let target = (location.x / bar.size.width) * music.songDuration
                    music.seek(to: max(0, min(target, music.songDuration)))
                }
            }
            .frame(height: max(8, width * 0.03))

            HStack {
                Text(timestamp(music.elapsedTime))
                Spacer()
                Text("-" + timestamp(max(0, music.songDuration - music.elapsedTime)))
            }
            .font(.system(size: width * 0.036, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(subtleInk)
        }
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
