import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardPrivacySettingsSection: View {
    @ObservedObject private var manager = ClipboardManager.shared
    @Default(.clipboardRetentionDays) private var retention
    @Default(.clipboardSkipSensitive) private var skipSensitive
    @Default(.clipboardIgnoredApps) private var ignoredApps

    private func highlightID(_ title: String) -> String { SettingsTab.clipboard.highlightID(for: title) }

    var body: some View {
        Section {
            Toggle("Pause capture", isOn: Binding(get: { manager.isCapturePaused }, set: manager.setCapturePaused))
                .settingsHighlight(id: highlightID("Pause clipboard capture"))
            Toggle("Skip copies marked private by password managers", isOn: $skipSensitive)
                .settingsHighlight(id: highlightID("Skip private clipboard copies"))
            Picker("Keep unpinned history", selection: $retention) {
                Text("Until the history limit").tag(0)
                Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
            }.settingsHighlight(id: highlightID("Clipboard history retention"))
                .onChange(of: retention) { _, _ in manager.refreshRetention() }
            ForEach(ignoredApps, id: \.self) { identifier in
                HStack {
                    Text(identifier).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Remove") { ignoredApps.removeAll { $0 == identifier } }
                }
            }
            Button("Ignore an application…") {
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                guard panel.runModal() == .OK, let url = panel.url, let identifier = Bundle(url: url)?.bundleIdentifier else { return }
                if !ignoredApps.contains(identifier) { ignoredApps.append(identifier) }
            }
            Text("Pinned items and collections survive history expiry. App labels and exclusions use the app active when a copy is captured. All history stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Capture & privacy") }
        Section {
            HStack {
                Button("Export history & pins…") { manager.exportBackup() }
                    .settingsHighlight(id: highlightID("Export clipboard backup"))
                Button("Import backup…") { manager.importBackup() }
                    .settingsHighlight(id: highlightID("Import clipboard backup"))
            }
            if let message = manager.workflowMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("Backups include copied text and images. Import merges with existing content and skips duplicates.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Backup") }
    }
}

