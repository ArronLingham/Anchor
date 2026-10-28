import Foundation

@main
struct DisplayLinkSupportTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        var state = DisplayLinkSnapshot()
        var policy = DisplayLinkLaunchPolicy()
        check(!policy.shouldLaunch(state, enabled: true), "Unknown USB inspection must not launch")
        check(state.status == "Checking display setup…", "Do not report missing before inspecting")
        state.inspected = true
        check(state.status == "USB hardware could not be checked", "An inspection error is not absent hardware")
        state.usbDevices = []
        state.appInstalled = true
        check(!policy.shouldLaunch(state, enabled: true), "Installing software does not add hardware")
        check(state.status == "No DisplayLink USB device detected", "Native/MST hub must not be labeled supported")
        state.usbDevices = [DisplayLinkDevice(id: 100, name: "USB graphics")]
        state.appInstalled = false
        check(!policy.shouldLaunch(state, enabled: true), "Cannot launch missing app")
        check(state.status.contains("install Manager"), "Give hardware-present setup advice")
        state.appInstalled = true
        check(!policy.shouldLaunch(state, enabled: false), "Opt-out must prevent launch")
        check(policy.shouldLaunch(state, enabled: true), "Launch once when enabled with hardware")
        for _ in 0..<100 {
            check(!policy.shouldLaunch(state, enabled: true), "Repeated notifications must not retry a failed launch")
        }
        state.appRunning = true
        check(!policy.shouldLaunch(state, enabled: true), "Running app needs no launch")
        check(state.status == "DisplayLink Manager is running", "Running is not proof of display/permission readiness")
        state.appRunning = false
        check(!policy.shouldLaunch(state, enabled: true), "Respect manual quit on screen/app notifications")
        policy.allowRetry()
        check(policy.shouldLaunch(state, enabled: true), "Wake permits a new attempt")
        check(!policy.shouldLaunch(state, enabled: true), "Wake attempt remains bounded")
        state.usbDevices = nil
        check(!policy.shouldLaunch(state, enabled: true), "USB error after attachment must block launch")
        state.usbDevices = [DisplayLinkDevice(id: 100, name: "USB graphics")]
        check(!policy.shouldLaunch(state, enabled: true), "Temporary inspection failure must not reset attempt")
        state.usbDevices = []
        policy.allowRetry()
        check(!policy.shouldLaunch(state, enabled: true), "Disconnect during settling prevents launch")
        state.usbDevices = [DisplayLinkDevice(id: 200, name: "USB graphics")]
        check(policy.shouldLaunch(state, enabled: true), "New USB attachment permits launch")
        state.usbDevices?.append(DisplayLinkDevice(id: 201, name: "Second adapter"))
        check(policy.shouldLaunch(state, enabled: true), "Another attached adapter changes topology")
        state.usbDevices?.reverse()
        check(!policy.shouldLaunch(state, enabled: true), "Enumeration order is not a new attachment")
        state.usbDevices?.removeFirst()
        check(!policy.shouldLaunch(state, enabled: true), "Removing one adapter must not restart a manually stopped app")
        policy.allowRetry()
        check(!policy.shouldLaunch(state, enabled: false), "Disable during settling prevents launch")
        policy.recordAttempt()
        check(!policy.shouldLaunch(state, enabled: true), "Manual launch failure must not trigger automatic retry")
        state.appRunning = true
        var alreadyRunning = DisplayLinkLaunchPolicy()
        check(!alreadyRunning.shouldLaunch(state, enabled: true), "App running at Anchor startup consumes attempt")
        state.appRunning = false
        check(!alreadyRunning.shouldLaunch(state, enabled: true), "Quit of pre-existing app is respected")
        state.model = "Mac14,2"
        check(state.nativeLimitMessage.contains("one native"), "2022 M2 Air native limit")
        state.model = "Mac15,12"
        check(!state.nativeLimitMessage.contains("one native"), "Do not impose M2 restriction on an M3")
        state.model = "FutureMac"
        check(!state.nativeLimitMessage.contains("one native"), "Unknown Macs require checked specs")
        check(DisplayLinkHardware.vendorID == 0x17e9, "Use documented USB VID")
        print("\(checks) DisplayLink checks passed")

        if CommandLine.arguments.contains("--live") {
            print("Model: \(DisplayLinkHardware.modelIdentifier())")
            print("DisplayLink USB devices: \(DisplayLinkHardware.devices().map { String($0.count) } ?? "inspection failed")")
            for screen in DisplayLinkHardware.screens() {
                print("Screen: \(screen.name), \(screen.mode), built-in=\(screen.builtIn), mirrored=\(screen.mirrored)")
            }
            print("AC power: \(String(describing: DisplayLinkHardware.onACPower()))")
            print("Lid closed: \(String(describing: DisplayLinkHardware.lidClosed()))")
        }
    }
}
