import CoreGraphics

/// The painted SwiftUI surface, excluding the host window's animation and
/// shadow clearance. Screen coordinates are Cocoa (bottom left); paths use
/// SwiftUI's top-left coordinates.
struct NotchClickRegion {
    let screenFrame: CGRect
    let bounds: CGRect
    let path: CGPath

    func contains(_ point: CGPoint) -> Bool {
        guard screenFrame.width > 0, screenFrame.height > 0,
              bounds.width > 0, bounds.height > 0,
              point.x.isFinite, point.y.isFinite,
              screenFrame.contains(point) else { return false }
        let local = CGPoint(
            x: bounds.minX + (point.x - screenFrame.minX) * bounds.width / screenFrame.width,
            y: bounds.minY + (screenFrame.maxY - point.y) * bounds.height / screenFrame.height)
        return path.contains(local)
    }
}

/// A slider or selection that started in the notch retains its mouse sequence
/// when dragged outside. A drag that started in another app does not claim it.
struct NotchMouseCapture {
    private(set) var buttons: Int = 0

    mutating func begin(button: Int) {
        guard (0..<(Int.bitWidth - 1)).contains(button) else { return }
        buttons |= 1 << button
    }

    mutating func shouldIgnore(inside: Bool, pressedButtons: Int, presented: Bool) -> Bool {
        guard presented else { buttons = 0; return true }
        buttons &= pressedButtons
        return !inside && buttons == 0
    }
}
