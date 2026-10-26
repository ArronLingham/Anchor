import AppKit

/// Primary windows share Dock presence. Floating utilities and notch panels do
/// not register, and minimizing a primary window keeps the app in the Dock.
@MainActor
final class AnchorApplicationPresentation {
    static let shared = AnchorApplicationPresentation()
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var utilityWindowsActive = false

    private init() {}

    func register(_ window: NSWindow) {
        windows.add(window)
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    func unregister(_ window: NSWindow) {
        windows.remove(window)
        if windows.allObjects.isEmpty && !utilityWindowsActive && NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func setUtilityWindowsActive(_ active: Bool) {
        utilityWindowsActive = active
        let policy: NSApplication.ActivationPolicy = active || !windows.allObjects.isEmpty ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
}
