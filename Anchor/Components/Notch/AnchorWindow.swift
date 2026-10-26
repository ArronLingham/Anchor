/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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

import Cocoa

class AnchorWindow: NSPanel {
    private weak var interactionSurface: NotchInteractionSurface?
    private var mouseCapture = NotchMouseCapture()

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .canJoinAllSpaces,
            .ignoresCycle,
            .stationary,
        ]
        
        isReleasedWhenClosed = false
        level = .mainMenu + 3
        hasShadow = false
        // Start click-through, including before SwiftUI's first layout. The
        // painted surface opts in; clear animation space never does.
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true

        ScreenCaptureVisibilityManager.shared.register(self, scope: .entireInterface)
    }
    
    override var canBecomeKey: Bool {
        true
    }
    
    override var canBecomeMain: Bool {
        true
    }

    func setInteractionSurface(_ surface: NotchInteractionSurface) {
        interactionSurface = surface
        refreshMouseInteractivity()
    }

    func hasInteractionSurface(_ surface: NotchInteractionSurface) -> Bool {
        interactionSurface === surface
    }

    #if DEBUG
    var reviewedClickRegion: NotchClickRegion? { interactionSurface?.clickRegion }
    #endif

    func removeInteractionSurface(_ surface: NotchInteractionSurface) {
        guard interactionSurface === surface else { return }
        interactionSurface = nil
        refreshMouseInteractivity()
    }

    func containsInteractivePoint(_ point: CGPoint) -> Bool {
        isVisible && alphaValue > 0.01 && interactionSurface?.clickRegion?.contains(point) == true
    }

    func refreshMouseInteractivity(at point: CGPoint = NSEvent.mouseLocation,
                                  pressedButtons: Int = NSEvent.pressedMouseButtons) {
        let region = interactionSurface?.clickRegion
        let presented = isVisible && alphaValue > 0.01 && region != nil
        let inside = presented && region?.contains(point) == true
        let ignored = mouseCapture.shouldIgnore(inside: inside, pressedButtons: pressedButtons,
                                                presented: presented)
        if ignoresMouseEvents != ignored { ignoresMouseEvents = ignored }
        interactionSurface?.updatePointerPresence(inside)
    }

    func beginMouseSequence(button: Int) {
        guard containsInteractivePoint(NSEvent.mouseLocation), !ignoresMouseEvents else { return }
        mouseCapture.begin(button: button)
    }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            // AppKit controls may consume mouse-up inside a nested tracking
            // loop. Refresh again when mouseDown returns so no stale drag
            // capture can leave transparent space intercepting clicks.
            refreshMouseInteractivity()
        default: break
        }
    }

    override var alphaValue: CGFloat {
        didSet { refreshMouseInteractivity() }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        refreshMouseInteractivity()
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        NotchPointerRouter.shared.add(self)
        refreshMouseInteractivity()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        NotchPointerRouter.shared.remove(self)
        refreshMouseInteractivity()
    }

    override func close() {
        NotchPointerRouter.shared.remove(self)
        super.close()
        refreshMouseInteractivity()
    }

}
