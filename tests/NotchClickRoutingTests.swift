import AppKit
import SwiftUI

// The production window's registration is unrelated to input routing. Keep
// this standalone test independent of screen-capture permissions and services.
final class ScreenCaptureVisibilityManager {
    enum Scope { case entireInterface }
    static let shared = ScreenCaptureVisibilityManager()
    func register(_ window: NSWindow, scope: Scope) {}
}

@main
struct NotchClickRoutingTests {
    @MainActor
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        // Exact outlines, including both curved corners and windows on
        // displays above/left of the primary display and scaled surfaces.
        for origin in [CGPoint(x: 445, y: 738), CGPoint(x: -1264, y: 1020), CGPoint(x: 610, y: -250)] {
            for size in [CGSize(width: 190, height: 32), CGSize(width: 460, height: 42), CGSize(width: 556, height: 420)] {
                let bounds = CGRect(origin: .zero, size: size)
                let path = CGPath(roundedRect: bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
                let region = NotchClickRegion(screenFrame: CGRect(origin: origin, size: size), bounds: bounds, path: path)
                check(region.contains(CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)), "Surface center must remain interactive")
                check(!region.contains(CGPoint(x: origin.x - 1, y: origin.y + size.height / 2)), "Transparent side margin must pass clicks")
                check(!region.contains(CGPoint(x: origin.x + size.width / 2, y: origin.y - 1)), "Transparent lower margin must pass clicks")
                check(!region.contains(CGPoint(x: origin.x + 0.5, y: origin.y + 0.5)), "Rounded clear corner must pass clicks")
            }
        }
        let asymmetrical = CGMutablePath()
        asymmetrical.addRect(CGRect(x: 0, y: 0, width: 200, height: 20))
        let scaled = NotchClickRegion(screenFrame: CGRect(x: -500, y: 400, width: 400, height: 80),
                                      bounds: CGRect(x: 0, y: 0, width: 200, height: 40), path: asymmetrical)
        check(scaled.contains(CGPoint(x: -300, y: 470)), "Flipped path top must map to screen top")
        check(!scaled.contains(CGPoint(x: -300, y: 410)), "Flipped path bottom must remain clear")
        check(!scaled.contains(CGPoint(x: CGFloat.infinity, y: 450)), "Invalid pointer must not claim input")
        check(!NotchClickRegion(screenFrame: .zero, bounds: .zero, path: asymmetrical).contains(.zero), "Unlaid-out content must pass clicks")

        var capture = NotchMouseCapture()
        check(capture.shouldIgnore(inside: false, pressedButtons: 1, presented: true), "An external drag must not capture the overlay")
        check(!capture.shouldIgnore(inside: true, pressedButtons: 0, presented: true), "Entering a visible control must enable input")
        capture.begin(button: 0)
        check(!capture.shouldIgnore(inside: false, pressedButtons: 1, presented: true), "An owned slider drag must survive leaving the shape")
        check(capture.shouldIgnore(inside: false, pressedButtons: 0, presented: true), "Mouse-up must release transparent space immediately")
        capture.begin(button: 1)
        check(!capture.shouldIgnore(inside: false, pressedButtons: 2, presented: true), "Right-button sequences must also complete")
        check(capture.shouldIgnore(inside: true, pressedButtons: 2, presented: false), "Hidden or disabled surfaces must release all input")
        check(capture.buttons == 0, "Hiding must clear mouse ownership")

        // Exercise the real AppKit window and the actual SwiftUI geometry
        // bridge, entirely off screen. Never move or synthesize the pointer.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = AnchorWindow(contentRect: CGRect(x: -20000, y: -20000, width: 580, height: 218),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        check(window.ignoresMouseEvents, "A fresh transparent host must start click-through")
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 580, height: 218))
        window.contentView = container
        let surface = NotchInteractionSurface(frame: CGRect(x: 190, y: 186, width: 200, height: 32))
        container.addSubview(surface)
        surface.apply(shape: AnyShape(Capsule()), enabled: true, onHover: { _ in })
        window.orderFrontRegardless()
        container.layoutSubtreeIfNeeded()
        func screen(_ point: CGPoint) -> CGPoint { window.convertPoint(toScreen: point) }
        let center = screen(CGPoint(x: 290, y: 202))
        let browser = screen(CGPoint(x: 290, y: 110))
        let corner = screen(CGPoint(x: 191, y: 187))
        check(window.containsInteractivePoint(center), "Painted notch must remain clickable")
        check(!window.containsInteractivePoint(browser), "YouTube search area below the closed notch must pass clicks")
        check(!window.containsInteractivePoint(corner), "Clear capsule corner must pass clicks")
        // These are the same browser-header rows caught by the installed
        // 580 x 218 host before the fix. All are below the painted 32 pt pill.
        for depth: CGFloat in [40, 75, 110, 160] {
            for x: CGFloat in [40, 290, 540] {
                let point = screen(CGPoint(x: x, y: 218 - depth))
                window.refreshMouseInteractivity(at: point, pressedButtons: 0)
                check(window.ignoresMouseEvents, "Transparent browser header must pass input at every sampled location")
            }
        }
        window.refreshMouseInteractivity(at: center, pressedButtons: 0)
        check(!window.ignoresMouseEvents, "Moving into the surface must enable its window")
        window.refreshMouseInteractivity(at: browser, pressedButtons: 0)
        check(window.ignoresMouseEvents, "Moving into empty host space must release the window")
        surface.apply(shape: AnyShape(Capsule()), enabled: false, onHover: { _ in })
        window.refreshMouseInteractivity(at: center, pressedButtons: 0)
        check(window.ignoresMouseEvents, "Disabled/locked controls must pass clicks")
        surface.apply(shape: AnyShape(Capsule()), enabled: true, onHover: { _ in })
        surface.setFrameSize(CGSize(width: 200, height: 80))
        surface.setFrameOrigin(CGPoint(x: 190, y: 138))
        check(window.containsInteractivePoint(screen(CGPoint(x: 290, y: 150))), "Expansion must update the native region")
        surface.setFrameSize(CGSize(width: 200, height: 32))
        surface.setFrameOrigin(CGPoint(x: 190, y: 186))
        check(!window.containsInteractivePoint(screen(CGPoint(x: 290, y: 150))), "Closing must release former content space")
        window.alphaValue = 0
        window.refreshMouseInteractivity(at: center, pressedButtons: 0)
        check(window.ignoresMouseEvents, "An alpha-hidden window must not intercept input")
        window.alphaValue = 1
        surface.removeFromSuperview()
        window.refreshMouseInteractivity(at: center, pressedButtons: 0)
        check(window.ignoresMouseEvents, "A detached renderer must release its old hit region")
        window.close()
        check(window.ignoresMouseEvents, "A closed window must release input")
        print("Notch click routing: \(checks) checks passed; no pointer or lock events")
    }
}
