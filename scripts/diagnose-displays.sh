#!/bin/bash
# What Anchor is actually doing on each display.
#
# Written because "no pill on the external monitor" cannot be checked from a
# terminal — there is no way to see the screen — but every input to that
# decision can be. If this prints a window on the external display at its top
# edge, the window is live and correctly placed, and anything still wrong is in
# what gets drawn, not where.
set -uo pipefail
cd "$(dirname "$0")/.."

echo "── settings that decide whether an external display gets a pill"
for k in showOnAllDisplays alwaysShowOnExternalDisplays externalDisplayStyle \
         hideNonNotchUntilHover hideNotchOption enableFullscreenMediaDetection \
         closedNotchWidth nonNotchHeight nonNotchHeightMode; do
  printf "   %-32s %s\n" "$k" "$(defaults read com.arronlingham.Anchor "$k" 2>/dev/null || echo '(default)')"
done

echo
echo "── displays, and Anchor's windows on them"
cat > /tmp/.anchor_disp.swift <<'EOF'
import AppKit
for s in NSScreen.screens {
    let notch = s.safeAreaInsets.top > 0 ? "physical notch" : "NO physical notch (pill is drawn)"
    print("   \"\(s.localizedName)\"  frame=\(s.frame)  \(notch)")
}
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
let list = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
let mine = list.filter { ($0[kCGWindowOwnerName as String] as? String) == "Anchor" }
print("   Anchor on-screen windows: \(mine.count)")
for w in mine {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = b["X"] as? Double ?? 0, y = b["Y"] as? Double ?? 0
    let ww = b["Width"] as? Double ?? 0, hh = b["Height"] as? Double ?? 0
    var on = "?"
    for s in NSScreen.screens where x >= s.frame.minX - 1 && x < s.frame.maxX {
        on = s.localizedName
        // CG y counts down from the main display's top; a window at the screen's
        // top edge therefore sits at mainHeight - screenTop.
        let mainH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? s.frame.height
        let expectedTop = mainH - s.frame.maxY
        let centred = (s.frame.minX + (s.frame.width - ww) / 2).rounded()
        on += "  [top edge: \(y == expectedTop ? "YES" : "no, expected \(expectedTop)")"
        on += ", centred: \(x.rounded() == centred ? "YES" : "no, expected \(centred)")]"
    }
    print("     layer=\(w[kCGWindowLayer as String] as? Int ?? 0)  \(Int(ww))x\(Int(hh)) at (\(Int(x)),\(Int(y)))  -> \(on)")
}
EOF
swiftc -O /tmp/.anchor_disp.swift -o /tmp/.anchor_disp 2>/dev/null && /tmp/.anchor_disp
rm -f /tmp/.anchor_disp /tmp/.anchor_disp.swift

echo
echo "── native HUD helper (T = Anchor has it suppressed, S = it can draw)"
if pgrep -x OSDUIHelper >/dev/null; then
  p=$(pgrep -x OSDUIHelper); echo "   OSDUIHelper pid=$p state=$(ps -o state= -p "$p" | tr -d ' ')"
else
  echo "   no OSDUIHelper running (it is spawned on demand)"
fi
