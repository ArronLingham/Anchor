import AppKit
import Defaults
import SwiftUI

struct DisplayLinkSettingsSection: View {
    @ObservedObject private var manager = DisplayLinkManager.shared
    @Default(.startDisplayLinkWhenConnected) private var automaticStart

    private var setup: DisplayLinkSnapshot { manager.snapshot }

    var body: some View {
        Section("Multiple monitors · DisplayLink") {
            Label(setup.status, systemImage: "display.2")
                .font(.headline)
            Text(setup.nativeLimitMessage)
                .font(.caption).foregroundStyle(.secondary)
            if let devices = setup.usbDevices, !devices.isEmpty {
                LabeledContent("USB hardware", value: devices.map(\.name).joined(separator: ", "))
            }
            LabeledContent("DisplayLink Manager", value: appStatus)
            Toggle("Start Manager when DisplayLink hardware connects", isOn: $automaticStart)
            Text("Also checks after wake while Anchor is running. Requires an installed DisplayLink Manager and a compatible USB adapter or dock.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if setup.appInstalled {
                    Button("Open DisplayLink Manager") { manager.openManager() }
                        .disabled(manager.launching)
                } else {
                    Link("Get DisplayLink Manager", destination: URL(string: "https://www.synaptics.com/products/displaylink-graphics/downloads/macos")!)
                }
                Button("Check again") { manager.refresh() }
            }
            if let error = manager.launchError { Text(error).font(.caption).foregroundStyle(.red) }
            if let warning = manager.monitoringWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
            DisclosureGroup("Connected displays and setup guide") {
                ForEach(setup.screens) { screen in
                    LabeledContent(screen.name, value: "\(screen.mode) · \(screen.builtIn ? "Built-in" : "External")\(screen.mirrored ? " · Mirrored" : "")")
                }
                Text("These are desktops reported by macOS. Manager running does not confirm its permission or a working DisplayLink screen.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Power", value: setup.onACPower.map { $0 ? "Power adapter connected" : "On battery" } ?? "Unknown")
                LabeledContent("Laptop lid", value: setup.lidClosed.map { $0 ? "Closed" : "Open" } ?? "Unavailable")
                guide("Connect the hardware", "Keep one monitor on your hub’s HDMI or DP output. Connect the second to a DisplayLink adapter on a USB 3 data port, or directly to the Mac. Ordinary HDMI/DP hubs cannot gain DisplayLink support through software.")
                guide("Allow access", "Unlock the Mac and allow the USB accessory. In System Settings, grant Screen Recording to DisplayLink Manager, then restart Manager. Complete its background activity setup. Anchor cannot check or grant these permissions for it.")
                HStack {
                    Button("Screen Recording settings") { openSettings("com.apple.preference.security?Privacy_ScreenCapture") }
                    Button("Arrange displays") { openSettings("com.apple.Displays-Settings.extension") }
                }
                guide("Use the Mac with its lid closed", "Connect power, a keyboard and a mouse. Check Manager’s lid-close sleep setting. With FileVault, the initial startup login needs a native screen or the laptop display.")
                guide("Choose a smooth setup", "Start with 60 Hz at the monitor’s native resolution and keep demanding motion on the native display. Protected streaming video may be unavailable on all screens while DisplayLink is connected. Check the current driver’s macOS support before an OS update.")
                Link("Official setup and limitations", destination: URL(string: "https://support.displaylink.com/knowledgebase/articles/1932214-displaylink-manager-app-for-macos-introduction-inst")!)
            }
        }
        .onAppear { manager.refresh() }
    }

    private var appStatus: String {
        guard setup.inspected else { return "Checking…" }
        guard setup.appInstalled else { return "Not installed" }
        return (setup.appVersion.map { "Version \($0) · " } ?? "") + (setup.appRunning ? "Running" : "Stopped")
    }

    private func guide(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}
