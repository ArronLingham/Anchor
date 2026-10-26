// Focus metadata only; never reads field contents or records keystrokes.
import AppKit
import ApplicationServices
import Darwin

func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}
func element(_ source: AXUIElement, _ key: String) -> AXUIElement? {
    guard let value = attribute(source,key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}
func snapshot(_ reason: String) {
    let system = AXUIElementCreateSystemWide()
    let front = NSWorkspace.shared.frontmostApplication
    var record: [String: Any] = ["time":Date().timeIntervalSince1970,"reason":reason,"front":front?.bundleIdentifier ?? "none"]
    if let focusedApp = element(system,kAXFocusedApplicationAttribute),
       let focus = element(focusedApp,kAXFocusedUIElementAttribute) {
        var pid: pid_t = 0; AXUIElementGetPid(focus,&pid)
        record["focusPID"] = pid
        record["focusApp"] = NSRunningApplication(processIdentifier:pid)?.bundleIdentifier ?? "none"
        record["role"] = attribute(focus,kAXRoleAttribute) as? String ?? "none"
        if record["focusApp"] as? String == "com.arronlingham.Anchor" {
            record["placeholder"] = attribute(focus,kAXPlaceholderValueAttribute) as? String ?? "none"
            if let window = element(focus,kAXWindowAttribute) { record["window"] = attribute(window,kAXTitleAttribute) as? String ?? "none" }
        }
    }
    let data = try! JSONSerialization.data(withJSONObject:record,options:[.sortedKeys])
    print(String(decoding:data,as:UTF8.self)); fflush(stdout)
}
let pid = pid_t(CommandLine.arguments[1])!
var observer: AXObserver?
let status = AXObserverCreate(pid,{ _,_,notification,_ in snapshot(notification as String) },&observer)
print("observerStatus=\(status.rawValue) trusted=\(AXIsProcessTrusted())"); fflush(stdout)
if status == .success, let observer {
    let target = AXUIElementCreateApplication(pid)
    for name in [kAXFocusedUIElementChangedNotification,kAXFocusedWindowChangedNotification,kAXWindowCreatedNotification] {
        AXObserverAddNotification(observer,target,name as CFString,nil)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
}
let token = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { _ in snapshot("appActivated") }
snapshot("initial")
RunLoop.main.run(until:Date().addingTimeInterval(CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 45))
NSWorkspace.shared.notificationCenter.removeObserver(token)
