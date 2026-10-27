import AppKit
import SwiftUI

@main
struct LiquidGlassRenderingTests {
    @MainActor
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func render<V: View>(_ view: V) -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.cgImage else { fatalError("Rendering failed") }
            return NSBitmapImageRep(cgImage: image)
        }
        func pixel(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
            image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        }

        let dark = render(Color.clear.frame(width: 80, height: 80)
            .modifier(AnchorGlassAccessibilitySurface(shape: Circle(), reduceTransparency: true, increasedContrast: false, colorScheme: .dark)))
        check(pixel(dark, 40, 40).alphaComponent > 0.99, "Reduced-transparency glass must be opaque")
        check(pixel(dark, 40, 40).redComponent < 0.3, "Dark fallback must remain dark")
        check(pixel(dark, 0, 0).alphaComponent < 0.01, "Fallback must preserve the supplied circular shape")

        let light = render(Color.clear.frame(width: 80, height: 80)
            .modifier(AnchorGlassAccessibilitySurface(shape: AnchorCorners.rectangle(cornerRadius: 16), reduceTransparency: true, increasedContrast: false, colorScheme: .light)))
        check(pixel(light, 40, 40).alphaComponent > 0.99, "Light fallback must be opaque")
        check(pixel(light, 40, 40).redComponent > 0.8, "Light fallback must remain light")
        check(pixel(light, 0, 0).alphaComponent < 0.01, "Fallback must preserve concentric corner clipping")

        let content = render(Color.blue.frame(width: 80, height: 80)
            .modifier(AnchorGlassAccessibilitySurface(shape: Rectangle(), reduceTransparency: true, increasedContrast: false, colorScheme: .dark)))
        check(pixel(content, 40, 40).blueComponent > 0.9, "Fallback must retain foreground content")

        let contrast = render(Color.clear.frame(width: 80, height: 80)
            .modifier(AnchorGlassAccessibilitySurface(shape: Rectangle(), reduceTransparency: true, increasedContrast: true, colorScheme: .dark))
            .environment(\.colorScheme, .dark))
        check(pixel(contrast, 40, 0).redComponent > pixel(contrast, 40, 40).redComponent,
              "Increased contrast must add a visible outline")
        print("Liquid Glass: \(checks) rendered accessibility checks passed")
    }
}
