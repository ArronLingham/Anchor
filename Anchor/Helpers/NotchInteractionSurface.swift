import AppKit
import SwiftUI

/// Measures the same clipped surface that is painted by ContentView. An
/// NSWindow's clear padding is otherwise still a mouse target in WindowServer.
struct NotchInteractionSurfaceReader: NSViewRepresentable {
    let shape: AnyShape
    let enabled: Bool
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> NotchInteractionSurface {
        let view = NotchInteractionSurface()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NotchInteractionSurface, context: Context) {
        view.apply(shape: shape, enabled: enabled, onHover: onHover)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NotchInteractionSurface,
                     context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

final class NotchInteractionSurface: NSView {
    private var shape = AnyShape(Rectangle())
    private var enabled = false
    private var path = CGMutablePath() as CGPath
    private var measuredBounds = CGRect.null
    private var onHover: (Bool) -> Void = { _ in }
    private weak var owner: AnchorWindow?
    private var proposedPresence = false
    private var reportedPresence = false
    private var presenceUpdatePending = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(shape: AnyShape, enabled: Bool, onHover: @escaping (Bool) -> Void) {
        self.shape = shape
        self.enabled = enabled
        self.onHover = onHover
        rebuildPath()
        owner?.refreshMouseInteractivity()
    }

    var clickRegion: NotchClickRegion? {
        guard enabled, let window, bounds.width > 0, bounds.height > 0 else { return nil }
        return NotchClickRegion(screenFrame: window.convertToScreen(convert(bounds, to: nil)),
                                bounds: bounds, path: path)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let next = window as? AnchorWindow
        if owner !== next {
            owner?.removeInteractionSurface(self)
            owner = next
        }
        rebuildPath()
        next?.setInteractionSurface(self)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        owner?.refreshMouseInteractivity()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildPath()
        owner?.refreshMouseInteractivity()
    }

    override func layout() {
        super.layout()
        if measuredBounds != bounds { rebuildPath() }
        owner?.refreshMouseInteractivity()
    }

    private func rebuildPath() {
        measuredBounds = bounds
        path = shape.path(in: bounds).cgPath
    }

    func updatePointerPresence(_ inside: Bool) {
        guard proposedPresence != inside else { return }
        proposedPresence = inside
        guard !presenceUpdatePending else { return }
        presenceUpdatePending = true
        // Geometry can change during a SwiftUI update. Coalesce into one
        // main-loop delivery instead of publishing state while laying out.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presenceUpdatePending = false
            guard self.owner?.hasInteractionSurface(self) == true,
                  self.reportedPresence != self.proposedPresence else { return }
            self.reportedPresence = self.proposedPresence
            self.onHover(self.proposedPresence)
        }
    }
}

/// One pair of event monitors for all displayed notch windows. No polling,
/// event suppression, click replay or pointer movement is needed.
@MainActor
final class NotchPointerRouter {
    static let shared = NotchPointerRouter()
    private let windows = NSHashTable<AnchorWindow>.weakObjects()
    private var localMonitor: Any?
    private var globalMonitor: Any?

    func add(_ window: AnchorWindow) {
        windows.add(window)
        guard localMonitor == nil else { return }
        let movement: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                              .otherMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: movement.union([.leftMouseDown, .rightMouseDown, .otherMouseDown])) { [weak self] event in
            MainActor.assumeIsolated {
                switch event.type {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    (event.window as? AnchorWindow)?.beginMouseSequence(button: event.buttonNumber)
                default: self?.refresh()
                }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: movement) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func remove(_ window: AnchorWindow) {
        windows.remove(window)
        guard windows.allObjects.isEmpty else { return }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func refresh() {
        let point = NSEvent.mouseLocation
        let buttons = NSEvent.pressedMouseButtons
        for window in windows.allObjects {
            window.refreshMouseInteractivity(at: point, pressedButtons: buttons)
        }
    }
}
