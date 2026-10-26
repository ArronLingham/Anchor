import AppKit
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
        let visible = manager.configuration.docks.filter(\.enabled)
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
            let icon = min(72, max(24, dock.iconSize))
            let length = Double(max(1, dock.apps.count)) * (icon + 10) + 44
            let size = CGSize(width: dock.vertical ? icon + 24 : min(bounds.width, length),
                              height: dock.vertical ? min(bounds.height, length) : icon + 24)
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

    private var dock: DesktopDock? { manager.configuration.docks.first { $0.id == id } }

    var body: some View {
        if let dock {
            let layout = dock.vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
            layout {
                DockDragHandle(vertical: dock.vertical)
                    .frame(width: dock.vertical ? dock.iconSize : 18, height: dock.vertical ? 18 : dock.iconSize)
                    .help("Drag \(dock.name) anywhere on a display")
                    .accessibilityLabel("Move \(dock.name)")
                if dock.apps.isEmpty {
                    Button { manager.chooseApps { apps in for app in apps { manager.addDockApp(app, to: id) } } } label: {
                        Image(systemName: "plus").frame(width: dock.iconSize, height: dock.iconSize)
                    }.buttonStyle(.plain).help("Add apps")
                } else {
                    ScrollView(dock.vertical ? .vertical : .horizontal, showsIndicators: false) {
                        let icons = dock.vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
                        icons {
                            ForEach(dock.apps) { app in
                                Button { manager.launch(app) } label: {
                                    ZStack(alignment: dock.vertical ? .leading : .bottom) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.applicationURL?.path ?? app.path))
                                            .resizable().scaledToFit().frame(width: dock.iconSize, height: dock.iconSize)
                                            .padding(3)
                                        if manager.runningBundleIDs.contains(app.bundleID) {
                                            Circle().fill(.primary.opacity(0.8)).frame(width: 4, height: 4)
                                        }
                                    }.frame(width: dock.iconSize + 8, height: dock.iconSize + 8)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).help(app.name).accessibilityLabel("Open \(app.name)")
                                .contextMenu {
                                    Button("Open \(app.name)") { manager.launch(app) }
                                    Button("Remove from Dock") {
                                        if let index = manager.configuration.docks.firstIndex(where: { $0.id == id }) {
                                            manager.configuration.docks[index].apps.removeAll { $0.bundleID == app.bundleID }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.16)))
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
