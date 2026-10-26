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
import Combine
import Defaults
import SwiftUI

/// Owns the desktop player's window.
///
/// Derived from Anchor's `VinylWidgetWindowManager` — the panel setup, the frame
/// autosave, the on-screen clamp and the display-sleep teardown all come from
/// there and were all worth keeping. What is new is everything to do with the
/// pointer: mouse resize, hover growth, and double-click to send to the back.
@MainActor
final class PlayerWindowManager: ObservableObject {
    static let shared = PlayerWindowManager()

    /// Width is the one thing the user sets directly. Height follows from what
    /// the layout needs, so there is never an empty strip at the bottom.
    @Published private(set) var width: CGFloat = Defaults[.playerWidth]
    @Published private(set) var isHovering = false

    private var panel: PlayerPanel?
    private var cancellables = Set<AnyCancellable>()
    private var hoverModel = PlayerHoverModel()

    private init() {}

    func start() {
        Defaults.publisher(.enablePlayerWidget, options: [])
            .sink { [weak self] _ in Task { @MainActor in self?.sync() } }
            .store(in: &cancellables)
        Defaults.publisher(.playerWindowLevel, options: [])
            .sink { [weak self] _ in Task { @MainActor in self?.applyLevel() } }
            .store(in: &cancellables)
        Defaults.publisher(.playerFollowsSpaces, options: [])
            .sink { [weak self] _ in
                Task { @MainActor in self?.panel?.applySpaceBehaviour() }
            }
            .store(in: &cancellables)
        // The budget is written by Reset in the editor, which is a different
        // window — without this the card keeps the old height until something
        // else happens to relayout it.
        //
        // Skipped while resizing, and that guard is load-bearing rather than
        // defensive: `applyUserSize` writes this key on EVERY step of a resize
        // drag, so without it each step did two relayouts instead of one, the
        // second of them animated — an animation started sixty times a second
        // that also fights the pointer it is chasing.
        Defaults.publisher(.playerHeightBudget, options: [])
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, !(self.panel?.isResizing ?? false) else { return }
                    self.relayout(animated: true)
                }
            }
            .store(in: &cancellables)
        Defaults.publisher(.playerLayouts, options: [])
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.cachedLayout = nil
                    self?.relayout(animated: true)
                }
            }
            .store(in: &cancellables)

        // The widget is torn down entirely while the display sleeps rather than
        // left running behind a black screen. Same reason the record's
        // CABasicAnimation is removed on pause rather than set to zero speed.
        SystemActivityGate.shared.$shouldSuspendBackgroundWork
            .receive(on: DispatchQueue.main)
            .sink { [weak self] suspended in
                MainActor.assumeIsolated { suspended == true ? self?.tearDown() : self?.sync() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clampOnScreen() }
        }

        sync()
    }

    // MARK: Lifecycle

    func sync() {
        guard Defaults[.enablePlayerWidget], !SystemActivityGate.shared.shouldSuspendBackgroundWork
        else {
            tearDown()
            return
        }
        if panel == nil { build() }
        relayout(animated: false)
        applyLevel()
        panel?.orderFrontRegardless()
    }

    private func build() {
        let host = NSHostingView(rootView: PlayerRootView(manager: self))
        host.translatesAutoresizingMaskIntoConstraints = true
        let size = NSSize(width: width, height: targetHeight(hovering: false))
        let created = PlayerPanel(contentView: host, size: size)

        created.onResize = { [weak self] proposed in
            MainActor.assumeIsolated { self?.applyUserSize(proposed) }
        }
        created.onHoverChange = { [weak self] hovering in
            MainActor.assumeIsolated { self?.setHovering(hovering) }
        }
        // One gesture, both directions. Sending to the back used to be a
        // one-way trip: the card was behind everything and double-clicking it
        // again did nothing, which reads as the widget having disappeared.
        created.onToggleFront = {
            MainActor.assumeIsolated {
                Defaults[.playerWindowLevel] =
                    Defaults[.playerWindowLevel] == .desktop ? .normal : .desktop
            }
        }
        created.onDragEnded = { [weak self] in
            MainActor.assumeIsolated { self?.persistFrame() }
        }
        created.isDeadSpace = { [weak self] point in
            MainActor.assumeIsolated { self?.isDeadSpace(at: point) ?? true }
        }

        // Named so it reads as "Cadence Player" in the Window menu rather than
        // as an untitled window, once a Dock icon makes that menu visible.
        created.title = "Anchor Player"
        created.setFrameAutosaveName("AnchorCadencePlayer")
        if created.frame.origin == .zero { created.setFrameOrigin(defaultOrigin(for: size)) }
        panel = created
        clampOnScreen()
    }

    private func tearDown() {
        guard let panel else { return }
        panel.saveFrame(usingName: "AnchorCadencePlayer")
        panel.orderOut(nil)
        self.panel = nil
    }

    func persistFrame() { panel?.saveFrame(usingName: "AnchorCadencePlayer") }

    // MARK: Size

    /// Cached, because `Defaults[.playerLayouts]` decodes JSON for **all four**
    /// surfaces on every read, and a resize drag reads it several times per
    /// mouse event — twice in `relayout`, once in `isDeadSpace`, once more in
    /// the view body. Invalidated by the same publisher that triggers a
    /// relayout, so it cannot go stale.
    private var cachedLayout: SurfaceLayout?

    private var layout: SurfaceLayout {
        if let cachedLayout { return cachedLayout }
        let resolved = Defaults[.playerLayouts].desktop
        cachedLayout = resolved
        return resolved
    }

    /// The height the window should be.
    ///
    /// When the user has dragged a vertical edge, that is a *budget*.
    ///
    /// Below the intrinsic height the solver drops elements to fit it. ABOVE it
    /// the window simply gets taller and the content centres in the extra room:
    /// the budget used to be clamped with `min(intrinsic, budget)`, so dragging
    /// to make the card taller was silently ignored and twenty drag steps gave
    /// twenty identical heights. Growing leaves an empty band by definition,
    /// which is what the user asked for and is not the `VinylWidgetSize.height`
    /// mistake — that was an empty strip nobody chose.
    private func targetHeight(hovering: Bool) -> CGFloat {
        let intrinsic = GridSolver.intrinsicHeight(
            layout: layout, width: width, hovering: hovering)
        let budget = Defaults[.playerHeightBudget]
        guard budget > 0 else { return intrinsic }
        return budget
    }

    private func applyUserSize(_ proposed: CGSize) {
        width = proposed.width
        Defaults[.playerWidth] = proposed.width
        // -1 means "this drag was horizontal only" — leave the budget alone
        // rather than pinning it to whatever the height happened to be, which
        // would silently freeze the layout after any sideways resize.
        if proposed.height >= 0 { Defaults[.playerHeightBudget] = proposed.height }
        relayout(animated: false)
    }

    /// Resize during a drag is not animated — an animation lagging behind the
    /// pointer feels like the window resisting.
    private func relayout(animated: Bool) {
        guard let panel else { return }
        let height = targetHeight(hovering: isHovering)
        // Anchored at the TOP edge: a widget that grows downward stays put where
        // the user left it. But at the bottom of a display there is nothing to
        // grow INTO, so the top anchor pushes the card off the edge and
        // `clampOnScreen` then yanks the whole thing upward — the card jumps
        // under the pointer, which is what "hover doesn't work well near the
        // bottom" is. When there is no room below, anchor the BOTTOM instead
        // and let it grow up.
        var originY = panel.frame.maxY - height
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame,
            originY < visible.minY
        {
            originY = min(panel.frame.minY, visible.maxY - height)
        }
        let target = NSRect(x: panel.frame.minX, y: originY, width: width, height: height)
        // Anchored at the TOP edge: a widget that grows downward stays put where
        // the user left it, whereas growing from the bottom-left origin makes
        // the whole card jump up the screen on hover.
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                // 0.24s in, matching the timings Anchor's music control window
                // arrived at.
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        clampOnScreen()
    }

    // MARK: Hover

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        guard Defaults[.hoverGrowsWidget], !(panel?.isResizing ?? false) else { return }

        // Only move the window if the hover set genuinely needs more room. A
        // hover-only button placed as an overlay adds no row, so nothing here
        // fires — which is the requirement, and the reason growth is derived
        // rather than configured.
        let metrics = GridSolver.hoverMetrics(layout: layout, width: width)
        guard metrics.grows else { return }
        relayout(animated: true)
    }

    /// Whether a point is somewhere a double-click should send the widget back.
    ///
    /// Asks the solver rather than guessing: anything whose `ElementMetrics`
    /// says it is interactive is not dead space.
    private func isDeadSpace(at point: CGPoint) -> Bool {
        guard let panel else { return true }
        let resolved = GridSolver.solve(
            layout: layout,
            available: CGSize(width: panel.frame.width, height: panel.frame.height),
            hovering: isHovering)
        return !resolved.elements.contains {
            $0.placement.element.metrics.isInteractive && $0.frame.contains(point)
        }
    }

    // MARK: Placement

    private func applyLevel() { panel?.level = Defaults[.playerWindowLevel].windowLevel }

    /// The display the card is currently on. `NSScreen.main` is "the screen
    /// with the key window", and this panel deliberately cannot become key, so
    /// it is the wrong answer here.
    var currentScreen: NSScreen? { panel?.screen }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        guard let visible = NSScreen.main?.visibleFrame else { return .zero }
        return NSPoint(x: visible.maxX - size.width - 40, y: visible.minY + 40)
    }

    /// Resizing keeps the origin, so shrinking or growing near a screen edge can
    /// walk a borderless panel off the display — and one you cannot see is one
    /// you cannot drag back. Anchor hit this going from Small (190pt) to Desktop
    /// (560pt) in the corner.
    private func clampOnScreen() {
        guard let panel,
            let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        var frame = panel.frame
        frame.origin.x = min(frame.origin.x, visible.maxX - frame.width)
        frame.origin.y = min(frame.origin.y, visible.maxY - frame.height)
        frame.origin.x = max(frame.origin.x, visible.minX)
        frame.origin.y = max(frame.origin.y, visible.minY)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }
}

/// Placeholder for hover state that will grow when the settings editor lands.
private struct PlayerHoverModel {}

// MARK: - Root view

private struct PlayerRootView: View {
    @ObservedObject var manager: PlayerWindowManager
    @ObservedObject private var music = MusicManager.shared

    @Default(.playerLayouts) private var layouts
    @Default(.playerTintsWithAlbum) private var tinted
    @Default(.playerBackgroundOpacity) private var backgroundOpacity
    @Default(.sliderColor) private var sliderColour
    @Default(.playerUsesGlass) private var usesGlass
    @Default(.accentColor) private var accentColour

    @State private var showingCloseChoice = false

    var body: some View {
        Group {
        PlayerSurfaceView(
            layout: layouts.desktop,
            style: .forSurface(
                .desktop, albumColor: music.avgColor, tinted: tinted && music.hasActiveSession,
                scale: layouts.desktop.geometry.contentScale,
                sliderColor: sliderColour, accentColor: accentColour),
            hovering: manager.isHovering,
            onExpand: { DesktopFullScreenController.shared.toggle() }
        )
        .background(AnchorSurface(depth: usesGlass ? .glass : .raised, radius: 22).opacity(backgroundOpacity))
        .overlay(RoundedRectangle(cornerRadius: 22).fill(cardColor.opacity(tinted && music.hasActiveSession ? 0.08 : 0)).allowsHitTesting(false))
        .overlay(alignment: .topTrailing) { closeButton }
        .contextMenu { menu }
        .animation(.easeInOut(duration: 0.35), value: music.avgColor)
            }
        .anchorTheme()
    }

    @ViewBuilder private var card: some View {
        // Liquid glass is the same public `glassEffect` the lock screen uses —
        // the API the macOS 26 floor was chosen for — which had exactly one
        // caller and was unreachable from the surface people actually look at.
        // The tint still applies over the top, at a low opacity, so an album
        // still colours the card without turning the glass into a flat fill.
        if usesGlass, #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(cardColor.opacity(backgroundOpacity * 0.35)))
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardColor.opacity(backgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    private var cardColor: Color {
        // An album colour with no album is not a colour to trust — the average
        // is taken from the placeholder glyph, which produced a pink card for a
        // player showing "Nothing playing".
        guard tinted, music.hasActiveSession else { return Color(white: 0.12) }
        return Color(nsColor: SurfaceStyle.muted(music.avgColor))
    }

    /// Closing offers a choice rather than doing something silently. Anchor's
    /// close button set the window level to desktop with no indication that is
    /// what it had done, so it read as a broken quit.
    @ViewBuilder private var closeButton: some View {
        // Stays mounted while its own popover is open. It used to be gated on
        // hover alone, so moving the pointer off the glyph towards the popover
        // unmounted the button — and a popover dies with the view it is
        // attached to. The menu appeared correctly and then vanished the moment
        // you tried to reach it.
        if manager.isHovering || showingCloseChoice {
            Button {
                showingCloseChoice = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(5)
                    .background(Circle().fill(.black.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .padding(8)
            .popover(isPresented: $showingCloseChoice, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Close the player").font(.headline)
                    Button("Send to the back") {
                        Defaults[.playerWindowLevel] = .desktop
                        showingCloseChoice = false
                    }
                    Text("Stays on the desktop, behind your windows.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Button("Hide desktop player") { Defaults[.enablePlayerWidget] = false }
                    Text("Turn it back on in Anchor Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(width: 250)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Picker("Position", selection: Binding(
            get: { Defaults[.playerWindowLevel] },
            set: { Defaults[.playerWindowLevel] = $0 })
        ) {
            ForEach(PlayerWindowLevel.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Toggle("Tint with the album colour", isOn: Binding(
            get: { Defaults[.playerTintsWithAlbum] },
            set: { Defaults[.playerTintsWithAlbum] = $0 }))
        Toggle("Grow on hover", isOn: Binding(
            get: { Defaults[.hoverGrowsWidget] },
            set: { Defaults[.hoverGrowsWidget] = $0 }))
        Divider()
        Button("Player settings…") {
            // Through SettingsWindowController, like the menu bar item. This
            // was still calling `showSettingsWindow:`, which finds no responder
            // in an LSUIElement app — so right-clicking the player and choosing
            // Player settings did nothing at all. The menu bar path was fixed
            // and this one was missed, which is the hazard of having two doors
            // to the same room.
            SettingsWindowController.shared.showWindow(tab: .media)
        }
    }
}
