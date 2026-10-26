import Foundation
import CoreGraphics

/// Hover callbacks can repeat after a keyboard selection redraws the wheel.
/// Only movement since the last accepted point may take selection back.
struct AppSwitcherPointerSelection {
    private(set) var lastPoint: CGPoint?
    private var isOutside = false

    init(initialPoint: CGPoint? = nil) {
        lastPoint = initialPoint
    }

    mutating func moved(to point: CGPoint, diameter: CGFloat, count: Int) -> Int? {
        if isOutside {
            isOutside = false
            lastPoint = point
            return Self.wedge(at: point, diameter: diameter, count: count)
        }
        guard let previous = lastPoint else {
            lastPoint = point
            return nil
        }
        guard hypot(point.x - previous.x, point.y - previous.y) >= 2 else { return nil }
        lastPoint = point
        return Self.wedge(at: point, diameter: diameter, count: count)
    }

    mutating func exited() { isOutside = true }

    static func wedge(at point: CGPoint, diameter: CGFloat, count: Int) -> Int? {
        guard count > 0, diameter.isFinite, diameter > 0,
              point.x.isFinite, point.y.isFinite else { return nil }
        let dx = point.x - diameter / 2
        let dy = point.y - diameter / 2
        let distance = hypot(dx, dy)
        guard distance > diameter * 0.16, distance <= diameter / 2 else { return nil }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        return Int((CGFloat(count) * angle / (2 * .pi)).rounded()) % count
    }
}
