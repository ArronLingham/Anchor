import AppKit
import ApplicationServices
import Combine

/// Settings-side inventory and Command-dragging of macOS menu extras.
/// Placement is owned and persisted by macOS, just as with a manual Command-drag.
@MainActor
final class MenuBarItemArranger: ObservableObject {
    struct Item: Identifiable, @unchecked Sendable {
        let id: String
        let name: String
        let icon: NSImage?
        let element: AXUIElement
        let bounds: CGRect
        var section: Section
    }
    enum Section: String, CaseIterable, Identifiable {
        case visible, hidden, alwaysHidden
        var id: String { rawValue }
        var label: String {
            switch self {
            case .visible: return "Visible"
            case .hidden: return "Hidden"
            case .alwaysHidden: return "Always hidden"
            }
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isMoving = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    @Published private(set) var isArranging = false
    private var operation: Task<Void, Never>?

    func begin() {
        guard !isMoving, !isRefreshing, MenuBarShrinkManager.shared.isActive else { return }
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            error = "Allow Anchor in System Settings → Privacy & Security → Accessibility, then choose Refresh Icons."
            return
        }
        isArranging = true
        MenuBarShrinkManager.shared.beginArrangingItems()
        operation?.cancel()
        operation = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func end() {
        operation?.cancel()
        operation = nil
        isArranging = false
        // A pending drag must release its mouse button before restoring dividers.
        if !isMoving { MenuBarShrinkManager.shared.endArrangingItems() }
    }

    private func refresh() async {
        guard isArranging else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let found = await Task.detached(priority: .userInitiated) { Self.discoverItems() }.value
        guard isArranging, !Task.isCancelled else { return }
        items = found.compactMap { item in
            let rect = item.bounds
            if item.id.hasPrefix("\(ProcessInfo.processInfo.processIdentifier)-"),
               MenuBarShrinkManager.shared.isDividerFrame(rect) { return nil }
            var updated = item
            updated.section = MenuBarShrinkManager.shared.section(for: rect)
            return updated
        }
        error = items.isEmpty ? "No accessible menu icons found. Reveal the menu bar and refresh. Some system controls cannot be moved by macOS." : nil
    }

    nonisolated private static func discoverItems() -> [Item] {
        var found: [Item] = []
        for app in NSWorkspace.shared.runningApplications {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.15)
            var bars: [AXUIElement] = []
            if let bar = attribute("AXExtrasMenuBar", of: root), CFGetTypeID(bar) == AXUIElementGetTypeID() { bars.append(bar as! AXUIElement) }
            if ["com.apple.systemuiserver", "com.apple.controlcenter"].contains(app.bundleIdentifier ?? ""),
               let bar = attribute(kAXMenuBarAttribute, of: root), CFGetTypeID(bar) == AXUIElementGetTypeID() { bars.append(bar as! AXUIElement) }
            for bar in bars {
                let children = attribute(kAXChildrenAttribute, of: bar) as? [AXUIElement] ?? []
                for (index, child) in children.enumerated() {
                    guard let rect = frame(child), rect.width > 0, rect.width < 400,
                          rect.height > 0, rect.height < 80 else { continue }
                    let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]
                        .compactMap { attribute($0, of: child) as? String }
                        .first { !$0.isEmpty } ?? "Menu icon \(index + 1)"
                    let name = "\(app.localizedName ?? "App") — \(label)"
                    if found.contains(where: { CFEqual($0.element, child) }) { continue }
                    found.append(Item(id: "\(app.processIdentifier)-\(found.count)", name: name,
                                      icon: app.icon, element: child, bounds: rect,
                                      section: .visible))
                }
            }
        }
        return found
    }

    func move(_ item: Item, to section: Section) {
        guard !isMoving, isArranging, section != item.section else { return }
        guard let source = Self.frame(item.element),
              let destination = MenuBarShrinkManager.shared.destination(for: section),
              Self.sameDisplay(source: CGPoint(x: source.midX, y: source.midY), destination: destination) else {
            error = "This icon and Anchor’s divider need to be visible on the same display. Make room in the menu bar and refresh."
            return
        }
        isMoving = true
        error = nil
        operation = Task {
            let start = CGPoint(x: source.midX, y: source.midY)
            let eventSource = CGEventSource(stateID: .hidSystemState)
            func post(_ type: CGEventType, _ point: CGPoint) {
                let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                                    mouseCursorPosition: point, mouseButton: .left)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
            var mouseIsDown = true
            post(.leftMouseDown, start)
            defer {
                if mouseIsDown { post(.leftMouseUp, destination) }
                isMoving = false
                if !isArranging { MenuBarShrinkManager.shared.endArrangingItems() }
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            for step in 1...12 {
                let fraction = CGFloat(step) / 12
                post(.leftMouseDragged, CGPoint(x: start.x + (destination.x - start.x) * fraction, y: start.y))
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { return }
            }
            post(.leftMouseUp, destination)
            mouseIsDown = false
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await refresh()
            if let rect = Self.frame(item.element), MenuBarShrinkManager.shared.section(for: rect) != section {
                error = "macOS did not move this icon. Try ⌘-dragging it, or change its visibility in the app that owns it."
            }
        }
    }

    private static func sameDisplay(source: CGPoint, destination: CGPoint) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        return NSScreen.screens.contains { screen in
            let rect = CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
                              width: screen.frame.width, height: screen.frame.height)
            return rect.contains(source) && rect.contains(destination)
        }
    }

    nonisolated private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(kAXPositionAttribute, of: element), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(kAXSizeAttribute, of: element), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
