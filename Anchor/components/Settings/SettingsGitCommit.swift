/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Defaults
import SwiftUI

struct GitCommitSettings: View {
    @Default(.gitDailyCommitEnabled) private var enabled
    @Default(.gitDailyCommitRepos) private var repos
    @Default(.gitDailyCommitHour) private var hour
    @Default(.gitDailyCommitMinute) private var minute
    @Default(.gitDailyCommitMessage) private var message
    @Default(.gitDailyCommitStageChanges) private var stageChanges
    @Default(.gitDailyCommitPush) private var push

    @ObservedObject private var manager = GitCommitManager.shared
    @State private var showingPushConfirmation = false

    private func highlightID(_ title: String) -> String {
        SettingsTab.gitCommit.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Commit once a day", isOn: $enabled)
                    .settingsHighlight(id: highlightID("Commit once a day"))
            } footer: {
                Text(
                    "Makes one commit a day in each repository below. By default "
                    + "that is an empty commit — a dated marker that changes no "
                    + "files. If the Mac is asleep at the scheduled time, the "
                    + "commit is made when it next wakes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Repositories") {
                if repos.isEmpty {
                    Text("No repositories chosen. Nothing will happen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(repos, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent)
                                Text(abbreviated(path))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                repos.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button("Add Repository…") { addRepo() }
                    .settingsHighlight(id: highlightID("Add Repository…"))
            }

            Section("When") {
                DatePicker(
                    "Time of day",
                    selection: Binding(
                        get: { timeOfDay },
                        set: { newValue in
                            let parts = Calendar.current.dateComponents(
                                [.hour, .minute], from: newValue)
                            hour = parts.hour ?? 21
                            minute = parts.minute ?? 7
                        }),
                    displayedComponents: .hourAndMinute)
                .disabled(!enabled)
                .settingsHighlight(id: highlightID("Time of day"))

                if let next = manager.nextRunAt, enabled {
                    LabeledContent("Next") {
                        Text(next.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
                if let last = manager.lastRunAt {
                    LabeledContent("Last") {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Commit") {
                TextField("Message", text: $message)
                    .disabled(!enabled)
                    .settingsHighlight(id: highlightID("Message"))
                    .help("{date} and {time} are replaced when the commit is made.")

                Text("Preview: \(manager.renderedMessage())")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Also commit uncommitted changes", isOn: $stageChanges)
                    .disabled(!enabled)
                    .settingsHighlight(id: highlightID("Also commit uncommitted changes"))
                    .help(
                        "Runs git add -A first. Off by default: an unattended "
                        + "sweep of the whole working tree will eventually commit "
                        + "a half-finished edit or a secret.")

                Toggle("Push after committing", isOn: Binding(
                    get: { push },
                    set: { wants in
                        // Turning it on is the one irreversible step here, so it
                        // is confirmed. Turning it off is not.
                        if wants { showingPushConfirmation = true } else { push = false }
                    }))
                    .disabled(!enabled)
                    .settingsHighlight(id: highlightID("Push after committing"))
                    .help("Committing is local and undoable. Pushing is neither.")
            }

            Section("Run now") {
                HStack {
                    Button("Commit Now") {
                        Task { await manager.run(trigger: "manual", force: true) }
                    }
                    .disabled(repos.isEmpty || manager.isRunning)

                    if manager.isRunning {
                        ProgressView().controlSize(.small)
                    }
                }
                .settingsHighlight(id: highlightID("Commit Now"))

                ForEach(manager.lastResults, id: \.repo) { record in
                    HStack(spacing: 6) {
                        Image(systemName: record.succeeded
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(record.succeeded ? .green : .orange)
                        Text(record.repo).font(.callout)
                        Spacer()
                        Text(record.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .confirmationDialog(
            "Let Anchor push automatically?",
            isPresented: $showingPushConfirmation,
            titleVisibility: .visible
        ) {
            Button("Enable Pushing") { push = true }
            Button("Cancel", role: .cancel) { push = false }
        } message: {
            Text(
                "Anchor will run git push in each repository after committing, "
                + "with no further prompt. A local commit can be undone; a push "
                + "cannot.")
        }
    }

    private var timeOfDay: Date {
        Calendar.current.date(
            bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Chooses a folder and checks it really is a work tree before storing it,
    /// so a mistake surfaces here rather than silently at 21:07.
    private func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Pick a git repository")

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            let path = url.path
            guard !repos.contains(path) else { continue }
            guard FileManager.default.fileExists(
                atPath: (path as NSString).appendingPathComponent(".git"))
            else {
                NSSound.beep()
                continue
            }
            repos.append(path)
        }
    }
}
