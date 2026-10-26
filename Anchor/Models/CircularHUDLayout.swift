import Foundation
import CoreGraphics

struct CircularHUDLayout {
    let diameter: CGFloat
    let stroke: CGFloat
    var canvasSize: CGFloat { diameter + 80 }

    init(diameter: CGFloat, stroke: CGFloat = 4) {
        self.diameter = diameter.isFinite ? min(200, max(40, diameter)) : 65
        self.stroke = stroke.isFinite ? min(self.diameter * 0.12, max(2, stroke)) : 4
    }

    func frame(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - canvasSize / 2, y: bounds.midY - canvasSize / 2,
               width: canvasSize, height: canvasSize).integral
    }

    static func normalized(_ value: CGFloat) -> CGFloat { value.isFinite ? min(1, max(0, value)) : 0 }
    static func percentage(_ value: CGFloat) -> String { String(Int((normalized(value) * 100).rounded())) }

    func knobOffset(value: CGFloat) -> CGPoint {
        let angle = (144 + 252 * Self.normalized(value)) * .pi / 180
        return CGPoint(x: diameter / 2 * cos(angle), y: diameter / 2 * sin(angle))
    }
}
