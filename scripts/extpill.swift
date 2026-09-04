import AppKit

// Structural probe for "permanent pill on an external monitor".
// Reports what the window server actually has, not what the code intends.

func read(_ k: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    p.arguments = ["read", "com.arronlingham.Anchor", k]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(unset)"
}

var fails = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "PASS" : "FAIL")  \(name)  — \(detail)")
    if !ok { fails += 1 }
}

let notchScreens = NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }
let extScreens  = NSScreen.screens.filter { $0.safeAreaInsets.top == 0 }
print("Screens:")
for s in NSScreen.screens {
    print("  \(s.localizedName)  frame=\(s.frame)  safeTop=\(s.safeAreaInsets.top)  \(s.safeAreaInsets.top > 0 ? "[has notch]" : "[EXTERNAL]")")
}
print("\nSettings:")
// `alwaysShowOnExternalDisplays` is THE external-pill switch — it alone makes
// AppDelegate.shouldUseMultiWindow true (so a window is built on every screen)
// and pins the non-notch ones above other spaces. The rest change how it looks
// or behaves, they do not gate its existence.
for k in ["alwaysShowOnExternalDisplays", "hideNonNotchUntilHover",
          "showOnAllDisplays", "openNotchOnHover", "extendHoverArea",
          "minimumHoverDuration", "hideNotchOption", "externalDisplayStyle"] {
    print("  \(k.padding(toLength: 30, withPad: " ", startingAt: 0)) \(read(k))")
}
print("")

guard !extScreens.isEmpty else {
    print("SKIP: no external display attached — plug one in and re-run.")
    exit(0)
}
guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.arronlingham.Anchor").first != nil else {
    print("FAIL: Anchor is not running."); exit(1)
}

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let list = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []

struct W { let idx: Int; let layer: Int; let alpha: Double; let rect: CGRect }
var anchorWins: [W] = []
for (i, w) in list.enumerated() where (w[kCGWindowOwnerName as String] as? String) == "Anchor" {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    anchorWins.append(W(idx: i,
        layer: w[kCGWindowLayer as String] as? Int ?? -1,
        alpha: w[kCGWindowAlpha as String] as? Double ?? -1,
        rect: CGRect(x: b["X"] as! Double, y: b["Y"] as! Double,
                     width: b["Width"] as! Double, height: b["Height"] as! Double)))
}

// Convert an external screen's top edge into CG (top-left origin) coords.
let globalTop = NSScreen.screens.map(\.frame.maxY).max()!
for ext in extScreens {
    let cgTop = globalTop - ext.frame.maxY
    let cgLeft = ext.frame.minX
    let band = CGRect(x: cgLeft, y: cgTop - 2, width: ext.frame.width, height: 90)
    let onExt = anchorWins.filter { $0.alpha > 0.01 && band.intersects($0.rect) && $0.rect.minY <= cgTop + 4 }

    print("== \(ext.localizedName) ==")
    check("T1 a pill window exists at this display's top edge",
          !onExt.isEmpty,
          onExt.isEmpty ? "no opaque Anchor window touching the top edge" : "\(onExt.count) window(s): \(onExt.map { "\($0.rect)" }.joined(separator: " "))")

    if let p = onExt.first {
        let inFront = list[0..<p.idx].filter { ($0[kCGWindowOwnerName as String] as? String) != "Anchor"
            && (($0[kCGWindowLayer as String] as? Int) ?? 0) < 1000 }
        check("T2 nothing at a normal window level covers it",
              inFront.isEmpty,
              inFront.isEmpty ? "clear" : "covered by \(inFront.compactMap { $0[kCGWindowOwnerName as String] as? String })")
        check("T3 it is opaque", p.alpha > 0.99, "alpha=\(p.alpha)")
        check("T4 it is horizontally centred on the display",
              abs(p.rect.midX - ext.frame.midX) < 2,
              "window midX=\(p.rect.midX) screen midX=\(ext.frame.midX)")
    }
    print("")
}
print(fails == 0 ? "STRUCTURAL: all passed" : "STRUCTURAL: \(fails) failed")
