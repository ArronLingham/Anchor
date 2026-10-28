import Foundation

struct DisplayLinkDevice: Equatable, Identifiable {
    let id: UInt64
    let name: String
}

struct DisplayLinkScreen: Equatable, Identifiable {
    let id: UInt32
    let name: String
    let mode: String
    let builtIn: Bool
    let mirrored: Bool
}

struct DisplayLinkSnapshot: Equatable {
    var inspected = false
    var usbDevices: [DisplayLinkDevice]? // nil means inspection failed, not no hardware
    var appInstalled = false
    var appRunning = false
    var appVersion: String?
    var model = ""
    var screens: [DisplayLinkScreen] = []
    var onACPower: Bool?
    var lidClosed: Bool?

    var status: String {
        guard inspected else { return "Checking display setup…" }
        guard let usbDevices else { return "USB hardware could not be checked" }
        guard !usbDevices.isEmpty else { return "No DisplayLink USB device detected" }
        guard appInstalled else { return "DisplayLink hardware found · install Manager" }
        return appRunning ? "DisplayLink Manager is running" : "DisplayLink Manager is stopped"
    }

    var nativeLimitMessage: String {
        switch model {
        case "MacBookAir10,1", "Mac14,2", "Mac14,15":
            return "This MacBook Air supports one native external monitor, with the lid open or closed. Another independent monitor needs USB graphics hardware such as DisplayLink."
        default:
            return "Native display limits depend on your Mac model. Extra video ports on a hub do not necessarily provide independent displays."
        }
    }
}

/// At most one automatic launch per attachment or wake. A manual quit or launch
/// failure must not produce a relaunch loop from app/screen notifications.
struct DisplayLinkLaunchPolicy {
    private var deviceIDs = Set<UInt64>()
    private var attempted = false

    mutating func allowRetry() { attempted = false }

    mutating func recordAttempt() { attempted = true }

    mutating func shouldLaunch(_ snapshot: DisplayLinkSnapshot, enabled: Bool) -> Bool {
        guard let devices = snapshot.usbDevices else { return false }
        let newIDs = Set(devices.map(\.id))
        if !newIDs.subtracting(deviceIDs).isEmpty { attempted = false }
        deviceIDs = newIDs
        if snapshot.appRunning { attempted = true }
        guard enabled, !deviceIDs.isEmpty, snapshot.appInstalled,
              !snapshot.appRunning, !attempted else { return false }
        attempted = true
        return true
    }
}
