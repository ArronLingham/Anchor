import AppKit

/// The Quick Panel is a floating control surface. Anchor's notch lives above
/// ordinary windows, including the transparent space around its visible pill.
/// Keep this panel above that surface so its title bar always receives clicks.
final class UtilityPanelWindow: NSPanel {
    init(contentViewController controller: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 332, height: 430),
                   styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "Anchor · Quick Panel"
        isReleasedWhenClosed = false
        isRestorable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        let size = controller.view.fittingSize
        if size.width > 1, size.height > 1 { setContentSize(size) }
    }

    /// Use the panel's current display, including its title bar and a margin.
    /// A panel moved from a tall display must scroll instead of falling below
    /// the smaller display when a larger section becomes visible.
    static func visibleFrame(on screen: NSScreen) -> NSRect {
        screen.visibleFrame.insetBy(dx: 16, dy: 16)
    }

    func maximumContentHeight(on screen: NSScreen) -> CGFloat {
        contentRect(forFrameRect: Self.visibleFrame(on: screen)).height
    }

    func constrainToScreen(_ screen: NSScreen) {
        let available = Self.visibleFrame(on: screen)
        var constrained = frame
        constrained.size.width = min(constrained.width, available.width)
        constrained.size.height = min(constrained.height, available.height)
        constrained.origin.x = min(max(constrained.minX, available.minX), available.maxX - constrained.width)
        constrained.origin.y = min(max(constrained.minY, available.minY), available.maxY - constrained.height)
        if constrained != frame { setFrame(constrained, display: true) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        // Text composition and child dialogs handle Escape before the window.
        guard attachedSheet == nil, NSApp.modalWindow == nil else { return }
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w",
           attachedSheet == nil, NSApp.modalWindow == nil {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
