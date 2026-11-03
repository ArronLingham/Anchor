import AppKit
import AnchorUtilities
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DesktopDockController {
    private unowned let manager: DesktopWorkspaceManager
    private var panels: [UUID: NSPanel] = [:]
    private var updating = false

    init(manager: DesktopWorkspaceManager) { self.manager = manager }

    func closeAll() {
        for panel in panels.values { panel.close() }
        panels.removeAll()
    }

    func reconcile() {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        let visible = manager.configuration.docks.filter { dock in
            dock.enabled && (manager.forceShowAllDocks || dock.workspaceModeIDs.isEmpty || manager.activeModeID.map(dock.workspaceModeIDs.contains) == true)
        }
        let ids = Set(visible.map(\.id))
        for id in Array(panels.keys) where !ids.contains(id) {
            panels.removeValue(forKey: id)?.close()
        }
        for dock in visible {
            guard let screen = NSScreen.screens.first(where: { LauncherWidgetProfile.screenID($0) == dock.displayID }) ?? NSScreen.screens.first else { continue }
            let panel: NSPanel
            if let existing = panels[dock.id] { panel = existing }
            else {
                panel = DesktopDockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = true
                panel.level = .floating
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                panel.isMovableByWindowBackground = false
                panels[dock.id] = panel
                (panel as? DesktopDockPanel)?.didDrag = { [weak self, weak panel] in
                    guard let self, let panel else { return }
                    self.manager.recordDockPosition(dock.id, frame: panel.frame)
                }
            }
            let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            let icon = min(128, max(32, dock.standardIconSize ? 48 : dock.iconSize))
            let itemCount = max(1, dock.apps.count + (dock.showsRecentApps ? manager.recentApps(for: dock.id).count : 0))
            let columns = max(1, dock.gridColumns ?? (dock.vertical ? 1 : itemCount))
            let rows = Int(ceil(Double(itemCount) / Double(columns)))
            let size = CGSize(width: min(bounds.width, CGFloat(columns) * (icon + 14) + 26),
                              height: min(bounds.height, CGFloat(rows) * (icon + 14) + 42))
            let origin = CGPoint(x: bounds.minX + max(0, bounds.width - size.width) * max(0, min(1, dock.x)),
                                 y: bounds.minY + max(0, bounds.height - size.height) * max(0, min(1, dock.y)))
            panel.title = dock.name
            panel.contentView = FirstMouseHostingView(rootView: DesktopDockView(id: dock.id, manager: manager))
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
            panel.orderFrontRegardless()
        }
    }
}

private final class DesktopDockPanel: NSPanel {
    var didDrag: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct DockDragHandle: NSViewRepresentable {
    let vertical: Bool
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) { view.vertical = vertical; view.needsDisplay = true }

    final class Handle: NSView {
        var vertical = true
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let panel = window as? DesktopDockPanel else { return }
            panel.performDrag(with: event)
            panel.didDrag?()
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.65).setFill()
            let rect = vertical ? CGRect(x: bounds.midX - 9, y: bounds.midY - 1.5, width: 18, height: 3)
                                : CGRect(x: bounds.midX - 1.5, y: bounds.midY - 9, width: 3, height: 18)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

struct DesktopDockView: View {
    let id: UUID
    @ObservedObject var manager: DesktopWorkspaceManager
    @State private var pointerInside = false

    private var dock: DesktopDock? { manager.configuration.docks.first { $0.id == id } }

    var body: some View {
        if let dock {
            let icon = dock.standardIconSize ? 48.0 : dock.iconSize
            let columnCount = max(1, dock.gridColumns ?? (dock.vertical ? 1 : max(1, dock.apps.count)))
            let columns = Array(repeating: GridItem(.fixed(icon), spacing: 6), count: columnCount)
            VStack(spacing: 4) {
                DockDragHandle(vertical: dock.vertical)
                    .frame(width: dock.vertical ? icon : 18, height: dock.vertical ? 18 : icon)
                    .help("Drag \(dock.name) anywhere on a display")
                    .accessibilityLabel("Move \(dock.name)")
                let entries = manager.dockEntries(for: id, includeRecent: dock.showsRecentApps)
                if entries.isEmpty {
                    Button { manager.chooseApps { apps in for app in apps { manager.addDockApp(app, to: id) } } } label: {
                        Image(systemName: "plus").frame(width: icon, height: icon)
                    }.buttonStyle(.plain).help("Add apps")
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(entries) { app in
                                Button { manager.launch(app) } label: {
                                    ZStack(alignment: dock.vertical ? .leading : .bottom) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.applicationURL?.path ?? app.path))
                                            .resizable().scaledToFit().frame(width: icon, height: icon)
                                            .padding(3)
                                        if manager.runningBundleIDs.contains(app.bundleID) {
                                            Circle().fill(.primary.opacity(0.8)).frame(width: 4, height: 4)
                                        }
                                    }.frame(width: icon + 8, height: icon + 8)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).help(app.name).accessibilityLabel("Open \(app.name)")
                                .contextMenu {
                                    Button("Open \(app.name)") { manager.launch(app) }
                                    if dock.apps.contains(where: { $0.bundleID == app.bundleID }) { Button("Remove from Dock") {
                                        if let index = manager.configuration.docks.firstIndex(where: { $0.id == id }) {
                                            manager.configuration.docks[index].apps.removeAll { $0.bundleID == app.bundleID }
                                        }
                                    } }
                                }
                            }
                        }
                    }
                }
            }
            .opacity(dock.autoHide && !pointerInside ? 0 : 1)
            .animation(.easeInOut(duration: 0.18), value: pointerInside)
            .onHover { pointerInside = $0 }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial, in: AnchorCorners.rectangle(cornerRadius: 18))
            .anchorCornerContainer(radius: 18)
            .overlay(AnchorCorners.rectangle(cornerRadius: 18).stroke(.white.opacity(0.16)))
            .padding(1)
            .preferredColorScheme(.dark)
            .contextMenu {
                Button("Edit Docks…") { SettingsWindowController.shared.showWindow(tab: .docks) }
                Button(dock.vertical ? "Make Horizontal" : "Make Vertical") {
                    if let index = manager.configuration.docks.firstIndex(where: { $0.id == id }) {
                        manager.configuration.docks[index].vertical.toggle()
                    }
                }
                Button("Hide This Dock") {
                    if let index = manager.configuration.docks.firstIndex(where: { $0.id == id }) {
                        manager.configuration.docks[index].enabled = false
                    }
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in
                            if let app = WorkspaceApp(url: url) { manager.addDockApp(app, to: id) }
                        }
                    }
                }
                return !providers.isEmpty
            }
        }
    }
}
