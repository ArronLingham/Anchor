import AppKit
import ApplicationServices

/// Uses public Accessibility APIs. Never creates documents or force-quits apps.
@MainActor
enum WorkspaceWindows {
    static var permitted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }

    static func windows(for app: NSRunningApplication) -> [AXUIElement] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.35)
        return (value(element, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            let role = value($0, kAXSubroleAttribute) as? String
            return role == kAXStandardWindowSubrole
        }
    }

    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let p = value(window, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(window, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// AX has a top-left origin on the primary display; AppKit has a bottom-left origin.
    static func axBounds(_ screen: NSScreen) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = screen.visibleFrame
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }

    static func capture() -> [WorkspaceWindow] {
        guard permitted else { return [] }
        var result: [WorkspaceWindow] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            guard let identity = WorkspaceApp(app) else { continue }
            for (index, window) in windows(for: app).enumerated() {
                guard (value(window, "AXFullScreen") as? Bool) != true,
                      let frame = frame(window),
                      let screen = NSScreen.screens.max(by: {
                          intersectionArea(frame, axBounds($0)) < intersectionArea(frame, axBounds($1))
                      }) else { continue }
                result.append(WorkspaceWindow(app: identity, title: value(window, kAXTitleAttribute) as? String ?? "",
                                              ordinal: index, displayID: LauncherWidgetProfile.screenID(screen),
                                              rect: .capture(frame, in: axBounds(screen))))
            }
        }
        return result
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    /// Return unresolved slots so the caller can retry apps which are still launching.
    static func restore(_ slots: [WorkspaceWindow], used: inout [String: [AXUIElement]]) -> (pending: [WorkspaceWindow], issues: [String]) {
        var pending: [WorkspaceWindow] = []
        var issues: [String] = []
        let grouped = Dictionary(grouping: slots, by: { $0.app.bundleID })
        for (bundleID, appSlots) in grouped {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
                  !app.isTerminated else { pending += appSlots; continue }
            let candidates = windows(for: app)
            let previous = used[bundleID] ?? []
            let unavailable = Set(candidates.indices.filter { index in previous.contains { CFEqual($0, candidates[index]) } })
            let titles = candidates.map { value($0, kAXTitleAttribute) as? String ?? "" }
            let matches = WorkspaceWindowMatching.plan(slots: appSlots, titles: titles, unavailable: unavailable)
            for slot in appSlots {
                guard let index = matches[slot.id] else { pending.append(slot); continue }
                guard let screen = NSScreen.screens.first(where: { LauncherWidgetProfile.screenID($0) == slot.displayID }) ?? NSScreen.screens.first else {
                    pending.append(slot); continue
                }
                let window = candidates[index]
                used[bundleID, default: []].append(window)
                if value(window, "AXFullScreen") as? Bool == true {
                    issues.append("\(slot.app.name): leave full screen to restore its layout.")
                    continue
                }
                let target = slot.rect.frame(in: axBounds(screen))
                _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                var point = target.origin
                var size = target.size
                guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { continue }
                // Some apps constrain size to the current display until they have moved.
                let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
                let resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
                let positioned = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
                if (moved != .success && positioned != .success) || resized != .success {
                    issues.append("\(slot.app.name): this window does not allow the saved position or size.")
                } else if let actual = frame(window), abs(actual.width - target.width) > 12 || abs(actual.height - target.height) > 12 || abs(actual.minX - target.minX) > 12 || abs(actual.minY - target.minY) > 12 {
                    issues.append("\(slot.app.name): the app adjusted its window to its supported size.")
                }
            }
        }
        return (pending, issues)
    }
}

extension WorkspaceApp {
    @MainActor
    init?(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier, let url = app.bundleURL else { return nil }
        self.init(bundleID: bundleID, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, path: url.path)
    }

    @MainActor
    init?(url: URL) {
        guard url.pathExtension == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        self.init(bundleID: id,
                  name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent,
                  path: url.path)
    }

    @MainActor
    var applicationURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        let url = URL(fileURLWithPath: path)
        guard Bundle(url: url)?.bundleIdentifier == bundleID else { return nil }
        return url
    }
}
