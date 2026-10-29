import AppKit
import SwiftUI

struct SettingsWorkspaceModes: View {
    @ObservedObject var manager = DesktopWorkspaceManager.shared
    @State private var selectedID: UUID?
    private func highlightID(_ title: String) -> String { SettingsTab.workspaceModes.highlightID(for: title) }

    var body: some View {
        Section {
            Toggle("Automatically switch modes", isOn: $manager.configuration.automationEnabled)
                .settingsHighlight(id: highlightID("Automatically switch modes"))
                .onChange(of: manager.configuration.automationEnabled) { _, enabled in
                    if enabled { manager.resumeAutomation() }
                }
            Text("Rules combine display and power conditions. The first matching mode in the list wins. Changes settle for two seconds before applying. Manual selections hold until your display or power setup changes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Label(manager.environment.externalDisplayIDs.isEmpty ? "No external display" : "External display connected", systemImage: "display")
                Spacer()
                Label(manager.environment.charging ? "Charging" : (manager.environment.onAC ? "Plugged in" : "On battery"), systemImage: "battery.100")
            }.font(.caption).foregroundStyle(.secondary)
            if manager.manualHold && manager.configuration.automationEnabled {
                Button("Resume Automatic Switching") { manager.resumeAutomation() }
            }
        } header: { Text("Automation") }

        Section {
            HStack {
                Picker("Mode", selection: $selectedID) {
                    Text("Choose a mode").tag(nil as UUID?)
                    ForEach(manager.configuration.modes) { mode in Text(mode.name).tag(Optional(mode.id)) }
                }
                Button("New Mode") {
                    let mode = WorkspaceMode()
                    manager.configuration.modes.append(mode)
                    selectedID = mode.id
                }
            }.settingsHighlight(id: highlightID("Choose a mode"))
                .onAppear { if selectedID == nil { selectedID = manager.configuration.modes.first?.id } }
            Text(manager.status).font(.callout).foregroundStyle(manager.issues.isEmpty ? Color.secondary : .orange)
            ForEach(manager.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        } header: { Text("Workspace modes") }

        if let index = manager.configuration.modes.firstIndex(where: { $0.id == selectedID }) {
            WorkspaceModeEditor(mode: $manager.configuration.modes[index], manager: manager)
                .id(selectedID)
        }

    }
}

private struct WorkspaceModeEditor: View {
    @Binding var mode: WorkspaceMode
    @ObservedObject var manager: DesktopWorkspaceManager
    @State private var showingDelete = false

    private var appsWithoutLayout: [WorkspaceApp] {
        let assignedIDs = Set(mode.windows.map { $0.app.id })
        return mode.apps.filter { !assignedIDs.contains($0.id) }
    }

    var body: some View {
        Section {
            TextField("Name", text: $mode.name)
            HStack {
                Button { manager.apply(mode.id) } label: {
                    HStack {
                        if manager.applying { ProgressView().controlSize(.small) }
                        Text(manager.applying ? "Applying…" : "Apply Mode")
                    }
                }
                    .disabled(manager.applying).buttonStyle(.borderedProminent)
                if manager.applying { Button("Stop") { manager.cancelApply() } }
                Button("Capture Current Apps & Layout") { manager.captureLayout(for: mode.id) }.disabled(manager.applying)
            }
            Text("Arrange your windows, then capture. Saved windows restore by title, with an app-window-order fallback. Apps must have a window or restored document; Anchor does not create documents. Full-screen windows are skipped during capture.")
                .font(.caption).foregroundStyle(.secondary)
            if !WorkspaceWindows.permitted {
                Button("Allow Accessibility for Window Layouts…") { WorkspaceWindows.requestAccess() }
            }
        } header: { Text("Mode setup") }

        Section {
            ForEach(mode.apps) { app in
                WorkspaceAppRow(app: app) {
                    Button("Remove") {
                        mode.apps.removeAll { $0.id == app.id }
                        mode.windows.removeAll { $0.app.id == app.id }
                    }
                }
            }
            Button("Add Apps to Open…") {
                manager.chooseApps { apps in
                    for app in apps where !mode.apps.contains(where: { $0.id == app.id }) {
                        mode.apps.append(app)
                        mode.quitApps.removeAll { $0.id == app.id }
                    }
                }
            }
            ForEach(mode.quitApps) { app in
                WorkspaceAppRow(app: app) { Button("Keep Open") { mode.quitApps.removeAll { $0.id == app.id } } }
            }
            Button("Add Apps to Quit…") {
                manager.chooseApps { apps in
                    for app in apps where app.bundleID != Bundle.main.bundleIdentifier && app.bundleID != "com.apple.finder" && !mode.quitApps.contains(where: { $0.id == app.id }) {
                        mode.quitApps.append(app)
                        mode.apps.removeAll { $0.id == app.id }
                        mode.windows.removeAll { $0.app.id == app.id }
                    }
                }
            }
            Text("Only listed apps receive quit requests. Unsaved-work prompts remain under each app’s control. Apps outside these lists stay as they are.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Apps to open and quit") }

        Section {
            if mode.windows.isEmpty { Text("Capture a layout, or add a window below.").foregroundStyle(.secondary) }
            ForEach($mode.windows) { $window in
                DisclosureGroup {
                    WorkspaceDisplayPicker(selection: $window.displayID)
                    Picker("Layout", selection: Binding(get: { preset(window.rect) }, set: { window.rect = rect($0) })) {
                        Text("Custom / captured").tag(-1)
                        Text("Full usable display").tag(0)
                        Text("Left half").tag(1)
                        Text("Right half").tag(2)
                        Text("Top half").tag(3)
                        Text("Bottom half").tag(4)
                        Text("Centered").tag(5)
                    }
                    fractionSlider("Left", value: $window.rect.x)
                    fractionSlider("Top", value: $window.rect.y)
                    fractionSlider("Width", value: $window.rect.width, range: 0.1...1)
                    fractionSlider("Height", value: $window.rect.height, range: 0.1...1)
                    Button("Remove Window") { mode.windows.removeAll { $0.id == window.id } }
                } label: {
                    Text("\(window.app.name) · \(window.title.isEmpty ? "Window \(window.ordinal + 1)" : window.title)").lineLimit(1)
                }
            }
            Menu("Add Window Layout") {
                ForEach(appsWithoutLayout) { app in
                    Button(app.name) {
                        let ordinal = mode.windows.filter { $0.app.id == app.id }.count
                        mode.windows.append(WorkspaceWindow(app: app, title: "", ordinal: ordinal, displayID: "", rect: WorkspaceRect()))
                    }
                }
            }.disabled(appsWithoutLayout.isEmpty)
            Text("Saved displays are identified across reconnections. Missing displays fall back to the primary display. Apps may enforce minimum sizes.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Window layouts") }

        Section {
            optionalSlider("Output volume", value: $mode.volume, initial: 0.4)
            optionalSlider("Built-in display brightness", value: $mode.brightness, initial: 0.6)
            Toggle("Set visible Anchor docks", isOn: Binding(get: { mode.visibleDockIDs != nil }, set: { mode.visibleDockIDs = $0 ? manager.configuration.docks.filter(\.enabled).map(\.id) : nil }))
            if mode.visibleDockIDs != nil {
                ForEach(manager.configuration.docks) { dock in
                    Toggle(dock.name, isOn: Binding(get: { mode.visibleDockIDs?.contains(dock.id) == true }, set: { visible in
                        mode.visibleDockIDs?.removeAll { $0 == dock.id }
                        if visible { mode.visibleDockIDs?.append(dock.id) }
                    }))
                }
            }
            TextField("Run macOS Shortcut (optional)", text: $mode.shortcutName)
            Text("A named Shortcut runs last. Use the Shortcuts app to add Focus, network, or other supported system settings. Applying a different mode changes only the settings enabled in that mode.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Settings") }

        Section {
            Toggle("Enable rule for this mode", isOn: $mode.rule.enabled)
            Picker("Display condition", selection: $mode.rule.display) {
                ForEach(WorkspaceDisplayCondition.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if mode.rule.display == .specificDisplay { WorkspaceDisplayPicker(selection: $mode.rule.displayID, label: "Required display", externalOnly: true) }
            Picker("Power condition", selection: $mode.rule.power) {
                ForEach(WorkspacePowerCondition.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if mode.rule.display == .specificDisplay && mode.rule.displayID.isEmpty {
                Text("Select an external display while it is connected to activate this rule.").font(.caption).foregroundStyle(.orange)
            }
            if mode.rule.display == .any && mode.rule.power == .any {
                Text("Choose at least one condition to make this rule active.").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Increase Priority") { reorder(-1) }.disabled(manager.configuration.modes.first?.id == mode.id)
                Button("Decrease Priority") { reorder(1) }.disabled(manager.configuration.modes.last?.id == mode.id)
                Spacer()
                Button("Delete Mode", role: .destructive) { showingDelete = true }
            }
        } header: { Text("Automatic switching rule") }
        .confirmationDialog("Delete \(mode.name)?", isPresented: $showingDelete) {
            Button("Delete Mode", role: .destructive) {
                let id = mode.id
                manager.configuration.modes.removeAll { $0.id == id }
            }
        }
    }

    private func reorder(_ offset: Int) {
        guard let index = manager.configuration.modes.firstIndex(where: { $0.id == mode.id }),
              manager.configuration.modes.indices.contains(index + offset) else { return }
        manager.configuration.modes.swapAt(index, index + offset)
    }

    private func fractionSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double> = 0...1) -> some View {
        LabeledContent("\(title) · \(Int(value.wrappedValue * 100))%") {
            Slider(value: value, in: range, step: 0.01).frame(width: 200)
        }
    }

    private func optionalSlider(_ title: String, value: Binding<Double?>, initial: Double) -> some View {
        VStack(alignment: .leading) {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? initial : nil }))
            if value.wrappedValue != nil {
                fractionSlider("Level", value: Binding(get: { value.wrappedValue ?? initial }, set: { value.wrappedValue = $0 }))
            }
        }
    }

    private func rect(_ index: Int) -> WorkspaceRect {
        switch index {
        case 1: return WorkspaceRect(width: 0.5)
        case 2: return WorkspaceRect(x: 0.5, width: 0.5)
        case 3: return WorkspaceRect(height: 0.5)
        case 4: return WorkspaceRect(y: 0.5, height: 0.5)
        case 5: return WorkspaceRect(x: 0.15, y: 0.1, width: 0.7, height: 0.8)
        default: return WorkspaceRect()
        }
    }
    private func preset(_ rect: WorkspaceRect) -> Int { (0...5).first { self.rect($0) == rect } ?? -1 }
}

struct WorkspaceModesMenu: View {
    @ObservedObject private var manager = DesktopWorkspaceManager.shared
    var body: some View {
        ForEach(manager.configuration.modes) { mode in
            Button {
                manager.apply(mode.id)
            } label: {
                Label(mode.name + (manager.activeModeID == mode.id ? " ✓" : ""), systemImage: mode.symbol)
            }.disabled(manager.applying)
        }
        Divider()
        if manager.manualHold && manager.configuration.automationEnabled {
            Button("Resume Automatic Switching") { manager.resumeAutomation() }
        }
        if manager.applying { Button("Stop Applying Mode") { manager.cancelApply() } }
        Button("Configure Modes…") { SettingsWindowController.shared.showWindow(tab: .workspaceModes) }
        Button("Configure Docks…") { SettingsWindowController.shared.showWindow(tab: .docks) }
    }
}
