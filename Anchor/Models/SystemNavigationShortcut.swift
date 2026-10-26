import AppKit

/// Only the exact system navigation chords belong to Anchor. Extra modifiers
/// must pass through, including Spotlight's Finder search (⌥⌘Space).
enum SystemNavigationShortcut: Equatable {
    case launcher
    case switcher(reverse: Bool)

    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                       launcherEnabled: Bool, switcherEnabled: Bool) -> Self? {
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])
        if launcherEnabled, keyCode == 49, modifiers == .command { return .launcher }
        if switcherEnabled, keyCode == 48 {
            if modifiers == .command { return .switcher(reverse: false) }
            if modifiers == [.command, .shift] { return .switcher(reverse: true) }
        }
        return nil
    }
}
