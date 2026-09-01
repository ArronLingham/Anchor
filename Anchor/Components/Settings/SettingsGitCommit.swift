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
    @Default(.gitDailyCommitRandomTime) private var randomTime
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

            GitCommitScheduleSection(highlightID: highlightID)

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
                .disabled(!enabled || randomTime)
                .settingsHighlight(id: highlightID("Time of day"))
                .help(randomTime
                      ? "Ignored while \"Commit at a random time\" is on — the window above decides."
                      : "The commit fires at this time each day.")

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
                    .settingsInfo("{date} and {time} are replaced when the commit is made.")

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
                    .settingsInfo("Committing is local and undoable. Pushing is neither.")
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

/// The scheduling options: how many, when, and with what message.
///
/// Split out of `GitCommitSettings` so that pane stays readable — it already
/// carries the repository list, the message template and the push switch.
struct GitCommitScheduleSection: View {
    @Default(.gitDailyCommitEnabled) private var enabled
    @Default(.gitDailyCommitRandomMessage) private var randomMessage
    @Default(.gitDailyCommitRandomTime) private var randomTime
    @Default(.gitDailyCommitWindowStartHour) private var windowStart
    @Default(.gitDailyCommitWindowEndHour) private var windowEnd
    @Default(.gitDailyCommitCount) private var commitCount

    let highlightID: (String) -> String

    var body: some View {
        Section("Schedule") {
            Stepper(value: $commitCount, in: 1...12) {
                LabeledContent("Commits per day") {
                    Text("\(commitCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!enabled)
            .settingsHighlight(id: highlightID("Commits per day"))
            .settingsInfo("More than one is spread evenly through the window rather than fired together.")

            Toggle("Commit at a random time", isOn: $randomTime)
                .disabled(!enabled)
                .settingsHighlight(id: highlightID("Commit at a random time"))
                .settingsInfo("Picks a time inside the window below. The draw is stable for a given day, so the target does not drift as the day goes on.")

            if randomTime {
                Picker("Not before", selection: $windowStart) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(Self.hourLabel(hour)).tag(hour)
                    }
                }
                .disabled(!enabled)
                .settingsHighlight(id: highlightID("Not before"))

                Picker("Not after", selection: $windowEnd) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(Self.hourLabel(hour)).tag(hour)
                    }
                }
                .disabled(!enabled)
                .settingsHighlight(id: highlightID("Not after"))
            }

            Toggle("Vary the commit message", isOn: $randomMessage)
                .disabled(!enabled)
                .settingsHighlight(id: highlightID("Vary the commit message"))
                .settingsInfo("Picks from a pool of plain housekeeping messages instead of the template above. They stay dull on purpose — the commits are empty, so a message implying real work would be a small lie in the log for ever.")
        }
    }

    private static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
