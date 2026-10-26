import AppKit
import Combine
import Darwin

/// Session-only display disconnection. No polling, helper process, or Lunar dependency.
@MainActor
final class ExternalMonitorController: ObservableObject {
    static let shared = ExternalMonitorController()
    @Published private(set) var isChangingDisplays = false
    @Published private(set) var displayControlMessage = ""
    private let savedKey = "Anchor.disconnectedExternalDisplayUUIDs"
    // Private macOS API: resolve dynamically and fail gracefully if macOS removes it.
    private typealias GetDisplayList = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> Int32
    private let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private var configureEnabled: ConfigureEnabled? {
        guard let skyLight, let symbol = dlsym(skyLight, "SLSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(symbol, to: ConfigureEnabled.self)
    }

    private func displayIDs(active: Bool) -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        let result: Int32
        if active {
            result = CGGetActiveDisplayList(64, &ids, &count).rawValue
        } else if let skyLight, let symbol = dlsym(skyLight, "SLSGetDisplayList") {
            // CoreGraphics omits software-disconnected displays; SkyLight retains them.
            let getAll = unsafeBitCast(symbol, to: GetDisplayList.self)
            result = getAll(64, &ids, &count)
        } else {
            result = CGGetOnlineDisplayList(64, &ids, &count).rawValue
        }
        guard result == 0 else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, value) as String
    }

    func disconnectExternalMonitors() {
        guard !isChangingDisplays else { return }
        let active = displayIDs(active: true)
        guard active.contains(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            fail("Open the MacBook lid before disconnecting external monitors.")
            return
        }
        let external = active.filter { CGDisplayIsBuiltin($0) == 0 }
        guard !external.isEmpty else { fail("No connected external monitor was found."); return }
        // Save hardware identities before committing so reconnect survives an Anchor restart.
        var saved = UserDefaults.standard.stringArray(forKey: savedKey) ?? []
        for id in external {
            guard let identity = uuid(id) else { fail("Could not identify the external monitor safely."); return }
            if !saved.contains(identity) { saved.append(identity) }
        }
        UserDefaults.standard.set(saved, forKey: savedKey)
        apply(external, enabled: false)
    }

    func reconnectMonitors() {
        guard !isChangingDisplays else { return }
        let saved = UserDefaults.standard.stringArray(forKey: savedKey) ?? []
        var targets = Set(displayIDs(active: false).filter { CGDisplayIsBuiltin($0) == 0 })
        for identity in saved {
            guard let value = CFUUIDCreateFromString(nil, identity as CFString) else { continue }
            let id = CGDisplayGetDisplayIDFromUUID(value)
            if id != 0 && CGDisplayIsBuiltin(id) == 0 { targets.insert(id) }
        }
        guard !targets.isEmpty else { fail("No monitor is available to reconnect. Check that the hub and VGA cable are plugged in."); return }
        apply(Array(targets), enabled: true)
    }

    private func apply(_ ids: [CGDirectDisplayID], enabled: Bool) {
        guard let configureEnabled else { fail("This macOS version does not support monitor disconnection."); return }
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else { fail("Could not begin display configuration (\(begin.rawValue))."); return }
        for id in ids {
            let result = configureEnabled(configuration, id, enabled)
            guard result == 0 else {
                CGCancelDisplayConfiguration(configuration)
                fail("Could not change the monitor connection (\(result)).")
                return
            }
        }
        // Never persist a disabled monitor in the system's permanent display configuration.
        let result = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard result == .success else { fail("Could not apply display configuration (\(result.rawValue))."); return }
        isChangingDisplays = true
        displayControlMessage = enabled ? "Reconnecting monitors…" : "Disconnecting external monitors…"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let active = Set(self.displayIDs(active: true))
            let confirmed = enabled ? ids.allSatisfy { active.contains($0) } : ids.allSatisfy { !active.contains($0) }
            self.isChangingDisplays = false
            if confirmed {
                self.displayControlMessage = enabled ? "Monitors reconnected" : "External monitors disconnected"
                if enabled { UserDefaults.standard.removeObject(forKey: self.savedKey) }
            } else {
                self.fail("The monitor connection change could not be confirmed. Try Reconnect Monitors, or unplug and reconnect the display cable.")
            }
        }
    }

    private func fail(_ message: String) {
        displayControlMessage = message
        let alert = NSAlert()
        alert.messageText = "Monitor connection"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
