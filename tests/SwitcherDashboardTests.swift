import Foundation
import CoreGraphics

@main struct SwitcherDashboardTests {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            guard condition() else { fatalError("FAIL: \(name)") }
            passed += 1
        }
        let diameter: CGFloat = 420
        let center = CGPoint(x: 210, y: 210)
        // Each corner starts outside the shifted circle. The very first entry
        // must select, and stationary hover delivery after Tab must not undo it.
        for origin in [CGPoint(x: -8, y: -8), CGPoint(x: 428, y: -8),
                       CGPoint(x: -8, y: 428), CGPoint(x: 428, y: 428), center] {
            var pointer = AppSwitcherPointerSelection(initialPoint: origin)
            let top = CGPoint(x: 210, y: 60)
            check("first entry from \(origin)", pointer.moved(to: top, diameter: diameter, count: 8) == 0)
            for _ in 0..<50 {
                check("Tab selection survives repeated hover", pointer.moved(to: top, diameter: diameter, count: 8) == nil)
            }
            check("subpixel jitter", pointer.moved(to: CGPoint(x: 210.5, y: 60.5), diameter: diameter, count: 8) == nil)
            check("real pointer movement takes over", pointer.moved(to: CGPoint(x: 360, y: 210), diameter: diameter, count: 8) == 2)
            check("dead hub preserves selection", pointer.moved(to: center, diameter: diameter, count: 8) == nil)
            check("leaving disc preserves selection", pointer.moved(to: CGPoint(x: -8, y: -8), diameter: diameter, count: 8) == nil)
            check("reenter selects immediately", pointer.moved(to: top, diameter: diameter, count: 8) == 0)
            pointer.exited()
            check("same-pixel reentry still selects", pointer.moved(to: top, diameter: diameter, count: 8) == 0)
            check("reentry then keyboard redraw preserves selection", pointer.moved(to: top, diameter: diameter, count: 8) == nil)
        }
        for count in [1, 2, 3, 8, 17, 32] {
            for index in 0..<count {
                let angle = CGFloat(index) * 2 * .pi / CGFloat(count) - .pi / 2
                let point = CGPoint(x: center.x + cos(angle) * 150, y: center.y + sin(angle) * 150)
                check("icon and wedge agree", AppSwitcherPointerSelection.wedge(at: point, diameter: diameter, count: count) == index)
            }
        }
        check("empty filtered list", AppSwitcherPointerSelection.wedge(at: CGPoint(x: 210, y: 60), diameter: diameter, count: 0) == nil)
        check("nonfinite point", AppSwitcherPointerSelection.wedge(at: CGPoint(x: CGFloat.nan, y: 60), diameter: diameter, count: 8) == nil)
        check("zero diameter", AppSwitcherPointerSelection.wedge(at: .zero, diameter: 0, count: 8) == nil)
        check("outside circle", AppSwitcherPointerSelection.wedge(at: .zero, diameter: diameter, count: 8) == nil)

        var layout = DashboardLayout.load(Data())
        for section in DashboardSection.allCases {
            check("fresh section defaults", layout.cards(in: section) == section.defaultCards)
        }
        layout.setVisible(false, card: .tasks, in: .overview)
        layout.setVisible(true, card: .soundDisplay, in: .overview)
        check("hide Tasks", !layout.cards(in: .overview).contains(.tasks))
        check("add Sound to Overview", layout.cards(in: .overview).contains(.soundDisplay))
        check("other tabs independent", layout.cards(in: .productivity) == DashboardSection.productivity.defaultCards)
        layout = DashboardLayout.load(layout.data)
        check("survives restart", !layout.cards(in: .overview).contains(.tasks) && layout.cards(in: .overview).contains(.soundDisplay))
        layout.setVisible(true, card: .soundDisplay, in: .overview)
        check("no duplicate cards", layout.cards(in: .overview).filter { $0 == .soundDisplay }.count == 1)
        for card in DashboardCard.allCases { layout.setVisible(false, card: card, in: .overview) }
        layout = DashboardLayout.load(layout.data)
        check("intentionally empty persists", layout.cards(in: .overview).isEmpty)
        check("empty rows", layout.rows(in: .overview).isEmpty)
        layout.restore(.overview)
        check("restore defaults", layout.cards(in: .overview) == DashboardSection.overview.defaultCards)
        let repaired = DashboardLayout.load(Data(#"{"sections":{"overview":["tasks","removed","tasks","soundDisplay"],"system":[]}}"#.utf8))
        check("stale and duplicate IDs", repaired.cards(in: .overview) == [.tasks, .soundDisplay])
        check("missing tab gets defaults", repaired.cards(in: .media) == DashboardSection.media.defaultCards)
        check("stored empty tab stays empty", repaired.cards(in: .system).isEmpty)
        check("corrupt storage fallback", DashboardLayout.load(Data("broken".utf8)).cards(in: .overview) == DashboardSection.overview.defaultCards)
        for section in DashboardSection.allCases {
            for card in DashboardCard.allCases { layout.setVisible(true, card: card, in: section) }
            let rows = layout.rows(in: section)
            check("no dropped cards in rows", rows.flatMap(\.cards) == layout.cards(in: section))
            check("stable unique rows", Set(rows.map(\.id)).count == rows.count)
            check("shelf uses full row", rows.first { $0.cards.contains(.shelf) }?.cards == [.shelf])
        }
        func utility(_ path: String, _ id: String?) -> Bool {
            LauncherAppVisibility.isSearchOnly(url: URL(fileURLWithPath: path), bundleIdentifier: id)
        }
        check("Font Book is search-only", utility("/System/Applications/Font Book.app", "com.apple.FontBook"))
        check("renamed/localized Font Book", utility("/Applications/Polices.app", "COM.APPLE.FONTBOOK"))
        check("Disk Utility is search-only", utility("/System/Applications/Utilities/Disk Utility.app", "com.apple.DiskUtility"))
        check("all built-in utilities covered", utility("/System/Applications/Utilities/New Maintenance Tool.app", nil))
        check("CoreServices tools hidden", utility("/System/Library/CoreServices/Applications/Archive Utility.app", "com.apple.archiveutility"))
        check("Terminal remains a regular app", !utility("/System/Applications/Utilities/Terminal.app", "com.apple.Terminal"))
        check("third-party utilities remain", !utility("/Applications/Utilities/Useful Tool.app", "org.example.tool"))
        check("similar third-party name remains", !utility("/Applications/Font Book.app", "org.example.fonts"))
        check("Safari remains", !utility("/System/Cryptexes/App/System/Applications/Safari.app", "com.apple.Safari"))
        check("System Settings remains", !utility("/System/Applications/System Settings.app", "com.apple.systempreferences"))
        check("normal built-in app remains", !utility("/System/Applications/Preview.app", "com.apple.Preview"))
        check("ordinary app remains", !utility("/Applications/Visual Studio Code.app", "com.microsoft.VSCode"))
        for query in ["screen", "s", "away", "locksmith", "cl", "clock", "display", "secure"] {
            check("ambiguous query cannot offer lock", !LauncherCommandIntent.allows("toggle.lockScreen", query: query))
        }
        for query in ["lock", "Lock Screen", "  LOCK   MAC  ", "secure mac"] {
            check("explicit lock intent remains", LauncherCommandIntent.allows("toggle.lockScreen", query: query))
        }
        check("ordinary commands unchanged", LauncherCommandIntent.allows("anchor.dashboard", query: "d"))
        check("stale lock ignored", !LockScreenEventPolicy.accepts(isLockedEvent: true, sessionIsLocked: false))
        check("stale unlock ignored", !LockScreenEventPolicy.accepts(isLockedEvent: false, sessionIsLocked: true))
        check("genuine lock accepted", LockScreenEventPolicy.accepts(isLockedEvent: true, sessionIsLocked: true))
        check("genuine unlock accepted", LockScreenEventPolicy.accepts(isLockedEvent: false, sessionIsLocked: false))
        check("unavailable session preserves lock fallback", LockScreenEventPolicy.accepts(isLockedEvent: true, sessionIsLocked: nil))
        check("unavailable session preserves unlock fallback", LockScreenEventPolicy.accepts(isLockedEvent: false, sessionIsLocked: nil))
        print("\(passed)/\(passed) switcher, Dashboard, launcher visibility, and lock-event checks passed")
    }
}
