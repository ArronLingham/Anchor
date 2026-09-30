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
import Foundation

/// Everything the renderer reads, in one value.
///
/// The renderer used to read `MusicManager.shared` directly, which made it
/// impossible to draw a surface against anything else — and the settings editor
/// needs exactly that: the *real* surface, with its real glass and tint and a
/// really spinning record, showing a track that does not change under the
/// cursor while you are arranging it.
///
/// A second `MusicManager` was the obvious alternative and is wrong: its `init`
/// wires up the controllers, so previewing a layout would start a second set of
/// AppleScript pollers against the user's music app.
struct PlayerSnapshot {
    var title: String
    var artist: String
    var album: String
    var artwork: NSImage
    var isPlaying: Bool
    var isShuffled: Bool
    var repeatMode: RepeatMode
    var isExplicit: Bool
    var bundleIdentifier: String?
    var duration: TimeInterval
    var showLyrics: Bool
    var currentLyric: String
    var hasSyncedLyrics: Bool
    var avgColor: NSColor
    /// False when nothing is playing and nothing is loaded.
    var hasTrack: Bool

    /// Where playback is at `date`.
    ///
    /// Live, this projects forward from the last reported time so a
    /// `TimelineView` animates smoothly while `MusicManager` stays quiet.
    /// Frozen, it ignores the date and returns a fixed position.
    var position: @Sendable (Date) -> TimeInterval

    static func live(_ music: MusicManager) -> PlayerSnapshot {
        PlayerSnapshot(
            title: music.songTitle,
            artist: music.artistName,
            album: music.album,
            artwork: music.albumArt,
            isPlaying: music.isPlaying,
            isShuffled: music.isShuffled,
            repeatMode: music.repeatMode,
            isExplicit: music.isCurrentTrackExplicit,
            bundleIdentifier: music.bundleIdentifier,
            duration: music.songDuration,
            showLyrics: music.showLyrics,
            currentLyric: music.currentLyrics,
            hasSyncedLyrics: !music.syncedLyrics.isEmpty,
            avgColor: music.avgColor,
            hasTrack: music.hasActiveSession,
            position: { date in
                MainActor.assumeIsolated { music.estimatedPlaybackPosition(at: date) }
            })
    }

    /// The track the settings preview shows.
    ///
    /// Deliberately fixed, and deliberately awkward: a long title so truncation
    /// is visible while you are arranging, a separate album name so the two text
    /// elements are distinguishable, and a duration whose elapsed and remaining
    /// halves differ so you can tell the two time readouts apart.
    static let sample = PlayerSnapshot(
        title: "A Song With A Deliberately Long Title",
        artist: "The Sample Artist",
        album: "Sample Album",
        artwork: sampleArtwork,
        isPlaying: true,
        isShuffled: false,
        repeatMode: .off,
        isExplicit: true,
        bundleIdentifier: nil,
        duration: 222,  // 3:42
        showLyrics: false,
        currentLyric: "",
        hasSyncedLyrics: false,
        avgColor: NSColor(calibratedRed: 0.42, green: 0.36, blue: 0.62, alpha: 1),
        hasTrack: true,
        position: { _ in 78 })  // 1:18 elapsed, -2:24 remaining

    /// A plausible cover, drawn rather than shipped as an asset.
    private static let sampleArtwork: NSImage = {
        let side: CGFloat = 512
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSGradient(
            starting: NSColor(calibratedRed: 0.35, green: 0.28, blue: 0.58, alpha: 1),
            ending: NSColor(calibratedRed: 0.72, green: 0.36, blue: 0.48, alpha: 1)
        )?.draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: 55)
        if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) {
            let box = NSRect(x: side * 0.3, y: side * 0.3, width: side * 0.4, height: side * 0.4)
            note.isTemplate = true
            NSColor.white.withAlphaComponent(0.85).set()
            note.draw(in: box, from: .zero, operation: .sourceOver, fraction: 0.85)
        }
        image.unlockFocus()
        return image
    }()
}

/// What a control does when clicked. `nil` throughout in the settings preview,
/// where a play button must look right and do nothing.
struct PlayerActions {
    var playPause: () -> Void
    var next: () -> Void
    var previous: () -> Void
    var seekBy: (TimeInterval) -> Void
    var seekTo: (TimeInterval) -> Void
    var toggleShuffle: () -> Void
    var toggleRepeat: () -> Void
    var toggleLyrics: () -> Void
    /// Clicking the artwork. Opens the full-screen view on the surfaces that
    /// have one; a no-op elsewhere, which is why it is an action rather than a
    /// hard-coded gesture inside the renderer.
    var expand: () -> Void = {}

    @MainActor static func live(_ music: MusicManager) -> PlayerActions {
        PlayerActions(
            playPause: { music.playPause() },
            next: { music.nextTrack() },
            previous: { music.previousTrack() },
            seekBy: { music.seek(by: $0) },
            seekTo: { music.seek(to: $0) },
            toggleShuffle: { music.toggleShuffle() },
            toggleRepeat: { music.toggleRepeat() },
            toggleLyrics: { music.toggleLyrics() })
    }

    /// Everything is a no-op. Used by the editor preview, where clicking a
    /// control selects it for editing rather than driving playback.
    static let inert = PlayerActions(
        playPause: {}, next: {}, previous: {}, seekBy: { _ in }, seekTo: { _ in },
        toggleShuffle: {}, toggleRepeat: {}, toggleLyrics: {}, expand: {})
}
