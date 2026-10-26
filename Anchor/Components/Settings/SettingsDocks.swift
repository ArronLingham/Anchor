import AppKit
import SwiftUI

struct SettingsDocks: View {
    @ObservedObject var manager = DesktopWorkspaceManager.shared
    private func highlightID(_ title: String) -> String { SettingsTab.docks.highlightID(for: title) }

    var body: some View {
        Section {
            HStack {
                Text("Create separate docks for work, communication, or tools.")
                Spacer()
                Menu("Add Dock") {
                    Button("Left · Vertical") { addDock(name: "Left Dock", vertical: true, x: 0, y: 0.5) }
                    Button("Right · Vertical") { addDock(name: "Right Dock", vertical: true, x: 1, y: 0.5) }
                    Button("Center · Horizontal") { addDock(name: "Center Dock", vertical: false, x: 0.5, y: 0.5) }
                    Button("Bottom · Horizontal") { addDock(name: "Bottom Dock", vertical: false, x: 0.5, y: 0) }
                }
            }.settingsHighlight(id: highlightID("Add Dock"))
            Text("Drag a dock by its handle to place it anywhere, including another display. Drop apps from Finder onto it, or add them below. These docks work alongside the macOS Dock.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Desktop docks") }

        ForEach($manager.configuration.docks) { $dock in
            Section {
                HStack {
                    TextField("Dock name", text: $dock.name)
                    Toggle("Visible", isOn: $dock.enabled).toggleStyle(.switch).fixedSize()
                }
                Picker("Orientation", selection: $dock.vertical) {
                    Text("Vertical").tag(true)
                    Text("Horizontal").tag(false)
                }
                WorkspaceDisplayPicker(selection: $dock.displayID)
                HStack {
                    Text("Position")
                    Spacer()
                    Button("Left") { dock.x = 0; dock.y = 0.5 }
                    Button("Center") { dock.x = 0.5; dock.y = 0.5 }
                    Button("Right") { dock.x = 1; dock.y = 0.5 }
                    Button("Bottom") { dock.x = 0.5; dock.y = 0 }
                }
                LabeledContent("Horizontal position") { Slider(value: $dock.x, in: 0...1).frame(width: 200) }
                LabeledContent("Vertical position") { Slider(value: $dock.y, in: 0...1).frame(width: 200) }
                LabeledContent("Icon size · \(Int(dock.iconSize))") { Slider(value: $dock.iconSize, in: 24...72, step: 2).frame(width: 200) }
                ForEach(dock.apps) { app in
                    WorkspaceAppRow(app: app) {
                        HStack(spacing: 6) {
                            Button { move(app, in: dock.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(dock.apps.first?.id == app.id).help("Move earlier")
                            Button { move(app, in: dock.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(dock.apps.last?.id == app.id).help("Move later")
                            Button("Remove") { dock.apps.removeAll { $0.id == app.id } }
                        }
                    }
                }
                HStack {
                    Button("Add Apps…") {
                        manager.chooseApps { apps in for app in apps { manager.addDockApp(app, to: dock.id) } }
                    }
                    Spacer()
                    Button("Delete Dock", role: .destructive) {
                        let id = dock.id
                        manager.configuration.docks.removeAll { $0.id == id }
                        for index in manager.configuration.modes.indices {
                            manager.configuration.modes[index].visibleDockIDs?.removeAll { $0 == id }
                        }
                    }
                }
            } header: { Text(dock.name.isEmpty ? "Dock" : dock.name) }
        }
    }

    private func addDock(name: String, vertical: Bool, x: Double, y: Double) {
        manager.configuration.docks.append(DesktopDock(name: name, vertical: vertical, x: x, y: y))
    }

    private func move(_ app: WorkspaceApp, in id: UUID, by offset: Int) {
        guard let index = manager.configuration.docks.firstIndex(where: { $0.id == id }),
              let appIndex = manager.configuration.docks[index].apps.firstIndex(of: app),
              manager.configuration.docks[index].apps.indices.contains(appIndex + offset) else { return }
        manager.configuration.docks[index].apps.swapAt(appIndex, appIndex + offset)
    }
}

struct WorkspaceDisplayPicker: View {
    @Binding var selection: String
    var label = "Display"
    var externalOnly = false
    private var displays: [NSScreen] {
        NSScreen.screens.filter { screen in
            guard externalOnly else { return true }
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return CGDisplayIsBuiltin(id) == 0
        }
    }
    var body: some View {
        Picker(label, selection: $selection) {
            Text(externalOnly ? "Choose an external display" : "Primary display").tag("")
            ForEach(displays, id: \.self) { screen in
                Text(screen.localizedName).tag(LauncherWidgetProfile.screenID(screen))
            }
            if !selection.isEmpty && !displays.contains(where: { LauncherWidgetProfile.screenID($0) == selection }) {
                Text("Saved display (disconnected)").tag(selection)
            }
        }
    }
}

struct WorkspaceAppRow<Actions: View>: View {
    let app: WorkspaceApp
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 22, height: 22)
            Text(app.name).lineLimit(1)
            Spacer()
            actions()
        }
    }
}
