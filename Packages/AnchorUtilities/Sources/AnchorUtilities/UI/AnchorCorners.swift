import SwiftUI

/// Shared corner policy for Anchor's native and utility surfaces. The minimum
/// preserves each control's rounding when it is far from its container's edges.
public enum AnchorCorners {
    public static func rectangle(cornerRadius: CGFloat) -> ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(max(0, cornerRadius))), isUniform: true)
    }
}

public extension View {
    /// Apply to the complete padded surface, not only its background. This gives
    /// descendants a real boundary from which SwiftUI can resolve concentricity.
    func anchorCornerContainer(radius: CGFloat) -> some View {
        containerShape(RoundedRectangle(cornerRadius: max(0, radius), style: .continuous))
    }

    func anchorRoundedClip(radius: CGFloat, antialiased: Bool = true) -> some View {
        clipShape(AnchorCorners.rectangle(cornerRadius: radius),
                  style: FillStyle(antialiased: antialiased))
            .anchorCornerContainer(radius: radius)
    }
}

public extension ConcentricRectangle {
    /// ConcentricRectangle is a Shape, not an InsettableShape. Clip the outside
    /// half of a double-width stroke to keep the border entirely inside the
    /// resolved path, sharing exactly the fill's corners and container context.
    func anchorStrokeBorder<S: ShapeStyle>(_ content: S, lineWidth: CGFloat = 1,
                                           antialiased: Bool = true) -> some View {
        stroke(content, style: StrokeStyle(lineWidth: lineWidth * 2), antialiased: antialiased)
            .clipShape(self, style: FillStyle(antialiased: antialiased))
    }
}
