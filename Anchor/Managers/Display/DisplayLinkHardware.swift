import AppKit
import IOKit
import IOKit.ps

enum DisplayLinkHardware {
    // Synaptics documents this VID for identifying DisplayLink USB products.
    static let vendorID = 0x17e9

    static func matchingDevices() -> CFDictionary? {
        guard let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return nil }
        match["idVendor"] = vendorID
        return match
    }

    static func devices() -> [DisplayLinkDevice]? {
        guard let matching = matchingDevices() else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [DisplayLinkDevice] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(device, &id) == KERN_SUCCESS else { continue }
            let name = IORegistryEntryCreateCFProperty(device, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            result.append(DisplayLinkDevice(id: id, name: name ?? "DisplayLink USB device"))
        }
        return result.sorted { $0.id < $1.id }
    }

    static func modelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else { return "" }
        return String(cString: value)
    }

    static func onACPower() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return nil }
        return source as String == kIOPSACPowerValue
    }

    static func lidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    @MainActor static func screens() -> [DisplayLinkScreen] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            let mode = CGDisplayCopyDisplayMode(id)
            let resolution = mode.map { "\($0.width) × \($0.height)" } ?? "Mode unavailable"
            let refresh = mode.map { $0.refreshRate > 0 ? String(format: " · %.0f Hz", $0.refreshRate) : "" } ?? ""
            return DisplayLinkScreen(id: id, name: screen.localizedName, mode: resolution + refresh,
                                     builtIn: CGDisplayIsBuiltin(id) != 0,
                                     mirrored: CGDisplayIsInMirrorSet(id) != 0)
        }
    }
}
