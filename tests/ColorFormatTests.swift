/*
 * Anchor — colour format tests
 *
 * `PickedColor` produces the eight strings the colour picker copies to the
 * clipboard. They are what the user pastes into a stylesheet, so a wrong
 * conversion is silently wrong work rather than a visible bug — and nothing
 * checked them.
 *
 * Compiles the real models/PickedColor.swift, so these cannot drift from it.
 */

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("ok    \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)")
    }
}

func equal(_ actual: String, _ expected: String, _ label: String) {
    checks += 1
    if actual == expected {
        print("ok    \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)\n        expected: \(expected)\n        actual:   \(actual)")
    }
}

@main
struct ColorFormatTests {
    static func main() {
        let red = PickedColor(red: 1, green: 0, blue: 0, point: .zero)
        let green = PickedColor(red: 0, green: 1, blue: 0, point: .zero)
        let blue = PickedColor(red: 0, green: 0, blue: 1, point: .zero)
        let white = PickedColor(red: 1, green: 1, blue: 1, point: .zero)
        let black = PickedColor(red: 0, green: 0, blue: 0, point: .zero)
        let grey = PickedColor(red: 0.5, green: 0.5, blue: 0.5, point: .zero)

        // MARK: - Hex

        equal(red.hexString, "#FF0000", "red is #FF0000")
        equal(green.hexString, "#00FF00", "green is #00FF00")
        equal(blue.hexString, "#0000FF", "blue is #0000FF")
        equal(white.hexString, "#FFFFFF", "white is #FFFFFF")
        equal(black.hexString, "#000000", "black is #000000")
        check(black.hexString.count == 7, "hex is # plus six digits, always padded")

        // MARK: - RGB

        equal(red.rgbString, "rgb(255, 0, 0)", "rgb components are 0-255, not 0-1")
        equal(white.rgbString, "rgb(255, 255, 255)", "white rgb")

        // MARK: - HSL
        //
        // Pure hues sit at known angles. Getting the hue sector wrong is the
        // classic bug in an RGB->HSL conversion and would be invisible in the
        // swatch, which is drawn from RGB.

        check(red.hslString.contains("hsl(0,"), "red hue is 0 (got \(red.hslString))")
        check(green.hslString.contains("hsl(120,"), "green hue is 120 (got \(green.hslString))")
        check(blue.hslString.contains("hsl(240,"), "blue hue is 240 (got \(blue.hslString))")
        check(white.hslString.contains("100%)"), "white is 100% lightness (got \(white.hslString))")
        check(grey.hslString.contains("0%"), "grey is 0% saturation (got \(grey.hslString))")

        // MARK: - HSV

        check(red.hsvString.contains("0"), "red hsv is produced (got \(red.hsvString))")
        check(!black.hsvString.isEmpty, "black hsv is produced")

        // MARK: - Alpha-carrying variants

        check(red.rgbaString.contains("1"), "rgba carries alpha (got \(red.rgbaString))")
        check(red.hslaString.contains("1"), "hsla carries alpha (got \(red.hslaString))")

        // MARK: - Code forms

        check(red.swiftUIString.contains("Color("), "SwiftUI form names Color")
        check(red.swiftUIString.contains("1.000"), "SwiftUI form uses 0-1 components")
        check(red.uiColorString.contains("UIColor("), "UIColor form names UIColor")

        // MARK: - Round trip through NSColor
        //
        // The picker builds a PickedColor from an NSColor, so that path has to
        // preserve the components it then formats.

        let viaNSColor = PickedColor(nsColor: red.nsColor, point: .zero)
        equal(viaNSColor.hexString, red.hexString, "NSColor round trip preserves the colour")

        // MARK: - allFormats is what Settings offers
        //
        // ColorPickerManager picks by name out of this list, so a rename here
        // silently breaks the copy format the user selected.

        let names = red.allFormats.map(\.name)
        check(names.contains("HEX"), "allFormats offers HEX — the default in Defaults")
        check(Set(names).count == names.count, "format names are unique")
        check(red.allFormats.allSatisfy { !$0.copyValue.isEmpty },
              "every format has something to copy")

        print("")
        print("\(checks - failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
