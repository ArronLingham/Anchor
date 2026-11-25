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

/// Retains only presses that actually reached an Anchor action. A key-up
/// corresponding to a press passed to macOS must also pass through.
struct NavigationKeyPresses {
    private var keys = Set<UInt16>()

    var isEmpty: Bool { keys.isEmpty }

    func contains(_ key: UInt16) -> Bool { keys.contains(key) }
    mutating func capture(_ key: UInt16) { keys.insert(key) }
    mutating func release(_ key: UInt16) -> Bool { keys.remove(key) != nil }

    mutating func discardReleased(isHeld: (UInt16) -> Bool) {
        keys = Set(keys.filter(isHeld))
    }
}
