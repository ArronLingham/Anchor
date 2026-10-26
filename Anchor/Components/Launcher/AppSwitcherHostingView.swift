import AppKit
import SwiftUI

/// The wheel never becomes key or activates Anchor. Track the pointer even
/// while another app is active, using the host's actual window coordinates.
@MainActor
final class AppSwitcherHostingView: NSHostingView<AppSwitcherView> {
    private let diameter: CGFloat
    private let tracksSystemPointer: Bool
    private var pointerSelection: AppSwitcherPointerSelection
    private var pointerArea: NSTrackingArea?

    init(diameter: CGFloat, initialPointerLocation: CGPoint, tracksSystemPointer: Bool = true) {
        self.diameter = diameter
        self.tracksSystemPointer = tracksSystemPointer
        pointerSelection = AppSwitcherPointerSelection(initialPoint: initialPointerLocation)
        super.init(rootView: AppSwitcherView(diameter: diameter))
        sizingOptions = []
        frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
    }

    required init?(coder: NSCoder) { fatalError("Use init(diameter:initialPointerLocation:)") }

    required init(rootView: AppSwitcherView) {
        diameter = rootView.diameter
        tracksSystemPointer = true
        pointerSelection = AppSwitcherPointerSelection()
        super.init(rootView: rootView)
        sizingOptions = []
        frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracksSystemPointer, pointerArea == nil else { return }
        let area = NSTrackingArea(rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { pointerSelection.exited() }

    private func track(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: local.x - bounds.minX,
                            y: isFlipped ? local.y - bounds.minY : bounds.maxY - local.y)
        let switcher = AppSwitcherManager.shared
        if let index = pointerSelection.moved(to: point, diameter: diameter, count: switcher.apps.count) {
            switcher.select(index)
        }
    }
}
