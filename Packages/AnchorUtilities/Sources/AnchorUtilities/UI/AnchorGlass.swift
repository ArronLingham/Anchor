import SwiftUI

/// The macOS counterpart of Expo's iOS GlassView: use the system's native
/// Liquid Glass renderer, keeping accessibility and corner policy in one place.
public extension View {
    func anchorLiquidGlass<S: Shape>(_ glass: Glass = .regular, in shape: S) -> some View {
        modifier(AnchorLiquidGlassModifier(glass: glass, shape: shape))
    }
}

private struct AnchorLiquidGlassModifier<S: Shape>: ViewModifier {
    let glass: Glass
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.modifier(AnchorGlassRendering(glass: glass, shape: shape,
            reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased,
            colorScheme: colorScheme))
    }
}

/// Resolved accessibility inputs keep the actual renderer independently testable
/// without changing system-wide accessibility preferences to run a test.
struct AnchorGlassRendering<S: Shape>: ViewModifier {
    let glass: Glass
    let shape: S
    let reduceTransparency: Bool
    let increasedContrast: Bool
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .modifier(AnchorGlassAccessibilitySurface(shape: shape,
                reduceTransparency: reduceTransparency, increasedContrast: increasedContrast,
                colorScheme: colorScheme))
            // Attach glass to the content as Apple prescribes. Putting a glass
            // view in background can capture and blur the foreground in a
            // GlassEffectContainer. Identity preserves the content's structure.
            .glassEffect(reduceTransparency ? .identity : glass, in: shape)
    }
}

/// Shared opaque surface and outline. ImageRenderer can verify these drawing
/// primitives; the system's GPU-backed glass needs a live window check.
struct AnchorGlassAccessibilitySurface<S: Shape>: ViewModifier {
    let shape: S
    let reduceTransparency: Bool
    let increasedContrast: Bool
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        // Keep content in one structural branch so accessibility changes do
        // not replace text fields or their focused editor.
        content
        .background {
            if reduceTransparency {
                shape.fill(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.94))
            }
        }
        .overlay {
            if increasedContrast {
                shape.stroke(.primary.opacity(0.5), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
