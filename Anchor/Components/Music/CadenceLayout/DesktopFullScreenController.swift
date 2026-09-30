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

/// The desktop player's full-screen view, opened by clicking its artwork.
///
/// Its own surface (`.desktopFull`) with its own layout. Sharing `.lockFull`'s
/// would be the exact mistake this project's four-surfaces rule exists to
/// prevent: a change to the lock screen would silently move an element here.
///
/// Deliberately an ordinary window, not the lock screen's shielded panel. This
/// one runs while the user is logged in and must behave like an app window —
/// Escape closes it, it takes key focus, and it appears in the window list.
@MainActor
final class DesktopFullScreenController {
    static let shared = DesktopFullScreenController()

    private var window: NSWindow?

    private init() {}

    var isOpen: Bool { window != nil }

    func toggle() { isOpen ? close() : open() }

    func open() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // The screen the player is on, not `NSScreen.main` — "the screen with
        // the key window" is the wrong answer when the click came from a
        // non-activating panel that cannot become key.
        let screen =
            PlayerWindowManager.shared.currentScreen ?? NSScreen.main ?? NSScreen.screens[0]

        let host = NSHostingView(rootView: DesktopFullScreenView())
        // Content view at init, not assigned afterwards: a borderless window
        // given its content later can end up with no backing store and never
        // reach the window server while still reporting isVisible == true.
        let created = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        created.contentView = host
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.level = .normal
        created.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        created.isReleasedWhenClosed = false
        created.setFrame(screen.frame, display: true)
        created.makeKeyAndOrderFront(nil)
        window = created
    }

    func close() {
        // Ordered out rather than closed. Anchor's notes record that closing a
        // window on a path like this, instead of ordering it out, crashes.
        window?.orderOut(nil)
        window = nil
    }
}

/// Borderless windows refuse key focus by default, and without it Escape never
/// arrives.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct DesktopFullScreenView: View {
    @ObservedObject private var music = MusicManager.shared
    @Default(.playerLayouts) private var layouts
    @Default(.sliderColor) private var sliderColour
    @Default(.accentColor) private var accentColour
    @Default(.lockFullBackground) private var background

    var body: some View {
        ZStack {
            backdrop
            PlayerSurfaceView(
                layout: layouts.desktopFull,
                style: .forSurface(
                    .desktopFull, albumColor: music.avgColor, tinted: false,
                    scale: layouts.desktopFull.geometry.contentScale,
                    sliderColor: sliderColour, accentColor: accentColour),
                // Clicking the artwork here closes it again, so the gesture
                // that opened it is also the way out.
                onExpand: { DesktopFullScreenController.shared.close() }
            )
            .padding(40)
        }
        .ignoresSafeArea()
        .background(KeyCatcher { DesktopFullScreenController.shared.close() })
        // A click anywhere that is not an element also closes. An immersive
        // view whose only exit is one small target reads as a trap.
        .onTapGesture { DesktopFullScreenController.shared.close() }
        .animation(.easeInOut(duration: 0.28), value: music.avgColor)
    }

    @ViewBuilder private var backdrop: some View {
        switch background {
        case .blurredArtwork:
            if music.hasActiveSession {
                Image(nsImage: music.albumArt)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 60, opaque: true)
                    .overlay(Color.black.opacity(0.45))
            } else {
                Color(white: 0.08)
            }
        case .albumColour:
            Color(nsColor: SurfaceStyle.muted(music.avgColor))
                .overlay(Color.black.opacity(0.25))
        }
    }
}

enum LockFullBackground: String, Codable, CaseIterable, Defaults.Serializable {
    case blurredArtwork
    case albumColour
}

/// Escape closes. An `NSViewRepresentable` rather than SwiftUI's `.onKeyPress`
/// because this window's content is a hosting view inside a borderless window,
/// and the responder chain needs a real first responder to route the key to.
private struct KeyCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onEscape = onEscape
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onEscape = onEscape
    }

    private final class CatcherView: NSView {
        var onEscape: () -> Void = {}
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEscape() } else { super.keyDown(with: event) }
        }
    }
}
