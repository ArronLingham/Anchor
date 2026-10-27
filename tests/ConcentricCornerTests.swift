import AppKit
import SwiftUI

@main
struct ConcentricCornerTests {
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
            guard let image = renderer.cgImage else { fatalError("Offscreen rendering failed") }
            return NSBitmapImageRep(cgImage: image)
        }
        func blue(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
            let color = image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            return color.blueComponent > 0.8 && color.redComponent < 0.2
        }

        // A fixed 4pt inner corner fills (12,12). Concentricity must instead
        // resolve it to 32 - 8 = 24pt and leave the red outer surface visible.
        let nested = render(ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous).fill(.red)
            AnchorCorners.rectangle(cornerRadius: 4).fill(.blue).padding(8)
        }.frame(width: 100, height: 100).anchorCornerContainer(radius: 32))
        check(blue(nested, 50, 50), "Nested content must render")
        for point in [(12, 12), (87, 12), (12, 87), (87, 87)] {
            check(!blue(nested, point.0, point.1), "Inner corners must follow the parent rather than a fixed 4pt radius")
        }

        let standalone = render(AnchorCorners.rectangle(cornerRadius: 12).fill(.blue)
            .frame(width: 80, height: 80))
        check(blue(standalone, 40, 40), "Standalone surfaces remain visible")
        check(!blue(standalone, 0, 0), "Minimum radius must preserve standalone rounding")

        let bordered = render(AnchorCorners.rectangle(cornerRadius: 12)
            .anchorStrokeBorder(Color.blue, lineWidth: 3).frame(width: 80, height: 80))
        check(blue(bordered, 40, 1), "Border must remain inside the surface")
        check(!blue(bordered, 40, 5), "Border thickness must remain 3pt")
        check(!blue(bordered, 40, 40), "Border must not fill the content")
        print("Concentric corners: \(checks) rendered geometry checks passed")
    }
}
