// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI
import Combine

final class ClipboardHistorySettingsObservation: ObservableObject {
    @Published private(set) var history: ClipboardHistoryService?
    private let makeHistory: () -> ClipboardHistoryService
    private var updates: AnyCancellable?

    init(available: Bool = AppFeature.clipboardHistory.isAvailable,
         makeHistory: @escaping () -> ClipboardHistoryService = { ClipboardHistoryService.shared }) {
        self.makeHistory = makeHistory
        synchronize(available: available)
    }

    func synchronize(available: Bool) {
        guard available else {
            updates = nil
            history = nil
            return
        }
        guard history == nil else { return }
        let service = makeHistory()
        updates = service.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        history = service
    }
}

struct ClipboardSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @StateObject private var historyObservation = ClipboardHistorySettingsObservation()
    @ObservedObject private var pastePlain = PastePlainService.shared
    @ObservedObject private var permissions = Permissions.shared
    @State private var clearingRequest: ClipboardClearRecentRequest?
    @AppStorage(DefaultsKey.pastePlainEnabled, store: UtilityPreferences.standard) private var pastePlainEnabled = false
    @AppStorage(DefaultsKey.clipboardHistoryEnabled, store: UtilityPreferences.standard) private var enabled = false
    @AppStorage(DefaultsKey.clipboardHistoryLimit, store: UtilityPreferences.standard) private var limit = 50
    @AppStorage(DefaultsKey.clipboardHistorySkipSensitive, store: UtilityPreferences.standard) private var skipSensitive = true
    @AppStorage(DefaultsKey.clipboardHistoryIncludeImagesFiles, store: UtilityPreferences.standard) private var includeImagesFiles = true
    @AppStorage(DefaultsKey.clipboardHistoryShortcutEnabled, store: UtilityPreferences.standard) private var shortcutEnabled = true
    @AppStorage(DefaultsKey.clipboardHistoryLayout, store: UtilityPreferences.standard) private var historyLayout = ClipboardHistoryLayout.list
    @AppStorage(DefaultsKey.clipboardHistoryMenuBarPreview, store: UtilityPreferences.standard) private var menuBarPreview = false
    @AppStorage(DefaultsKey.clipboardHistoryMenuBarPreviewLength, store: UtilityPreferences.standard)
    private var menuBarPreviewLength = Defaults.defaultClipboardMenuBarPreviewLength
    @AppStorage(DefaultsKey.panelUtilityClipboard, store: UtilityPreferences.standard) private var showInPanel = true
    @AppStorage(DefaultsKey.finderPasteImageAsFile, store: UtilityPreferences.standard) private var pasteImageAsFile = false
    @AppStorage(DefaultsKey.clipboardAutoClearOnDelay, store: UtilityPreferences.standard) private var autoClearOnDelay = false
    @AppStorage(DefaultsKey.clipboardAutoClearDelay, store: UtilityPreferences.standard)
    private var autoClearDelay = Defaults.defaultClipboardAutoClearDelay
    @AppStorage(DefaultsKey.clipboardAutoClearOnSleep, store: UtilityPreferences.standard) private var autoClearOnSleep = false
    @AppStorage(DefaultsKey.clipboardAutoClearOnDisplaySleep, store: UtilityPreferences.standard) private var autoClearOnDisplaySleep = false
    @AppStorage(DefaultsKey.clipboardAutoClearOnScreenLock, store: UtilityPreferences.standard) private var autoClearOnScreenLock = false

    private var text: ClipboardFeatureStrings {
        FeatureStrings.clipboard(l10n.language)
    }

    var body: some View {
        Form {
            if AppFeature.clipboardHistory.isAvailable, let history = historyObservation.history {
                Section {
                    Toggle(text.enable, isOn: $enabled)
                        .onChange(of: enabled) { _, _ in
                            if AppFeature.clipboardHistory.isAvailable { history.syncWithPreferences() }
                        }
                    Text(text.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(text.localNote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if enabled, history.isRunning {
                        Label(text.active, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .settingsFormSectionAnchor(.clipboardHistory)

                clipboardShortcutSection(history: history)
                clipboardMenuBarPreviewSection

                Section {
                    Toggle(text.includeImagesFiles, isOn: $includeImagesFiles)
                        .disabled(!enabled)
                    Text(text.includeImagesFilesCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(text.skipSensitive, isOn: $skipSensitive)
                        .disabled(!enabled)
                    Text(text.skipSensitiveCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ClipboardIgnoredAppsList()
                        .disabled(!enabled)
                    Picker(text.limit, selection: $limit) {
                        ForEach(Defaults.allowedClipboardHistoryLimits, id: \.self) { value in
                            Text(value == 0 ? text.limitUnlimited : "\(value)").tag(value)
                        }
                    }
                    .disabled(!enabled)
                }

                // Its own section because it is the one setting here that keeps
                // working with capture off: the panel entry stays, saying so,
                // and still opens the saved items. Sitting among the disabled
                // rows it read as one that had been missed.
                Section {
                    Toggle(text.showInPanel, isOn: $showInPanel)
                }

            }

            if AppFeature.clipboardHistory.isAvailable {
                clipboardAutoClearSection
            }

            if AppFeature.finderCutPaste.isAvailable {
                Section {
                    Toggle(text.pasteImageAsFile, isOn: $pasteImageAsFile)
                        .onChange(of: pasteImageAsFile) { _, _ in
                            FinderCutPaste.shared.syncWithPreferences()
                        }
                    Text(text.pasteImageAsFileCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if pasteImageAsFile, !permissions.accessibility {
                        PermissionRow(kind: .accessibility)
                    }
                }
            }

            if AppFeature.pastePlain.isAvailable {
                Section {
                    Toggle(l10n.s.pastePlainName, isOn: $pastePlainEnabled)
                        .onChange(of: pastePlainEnabled) { _, _ in
                            PastePlainService.shared.syncWithPreferences()
                        }
                    Text(l10n.s.pastePlainCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ShortcutPreferenceRow(role: .pastePlain,
                                          isEnabled: pastePlainEnabled) {
                        PastePlainService.shared.syncWithPreferences()
                    }
                    if pastePlainEnabled, pastePlain.shortcutRegistrationFailed {
                        Text(l10n.s.shortcutUnavailable)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if pastePlainEnabled, !permissions.accessibility {
                        PermissionRow(kind: .accessibility)
                    }
                } header: {
                    Text(l10n.s.pastePlainName)
                }
                .settingsFormSectionAnchor(.pastePlain)
            }

            if AppFeature.clipboardHistory.isAvailable, let history = historyObservation.history {
                clipboardStatsSection(history: history)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            historyObservation.synchronize(available: AppFeature.clipboardHistory.isAvailable)
            limit = Defaults.sanitizedClipboardHistoryLimit(limit)
            autoClearDelay = Defaults.sanitizedClipboardAutoClearDelay(autoClearDelay)
            menuBarPreviewLength = Defaults.sanitizedClipboardMenuBarPreviewLength(menuBarPreviewLength)
        }
        .onChange(of: features.revision) { _, _ in
            historyObservation.synchronize(available: AppFeature.clipboardHistory.isAvailable)
            if !AppFeature.clipboardHistory.isAvailable { clearingRequest = nil }
        }
        .onChange(of: limit) { _, value in
            let sanitized = Defaults.sanitizedClipboardHistoryLimit(value)
            if sanitized != value { limit = sanitized }
            if AppFeature.clipboardHistory.isAvailable {
                historyObservation.history?.trimToLimit()
            }
        }
        // No syncWithPreferences() here, unlike the auto-clear toggles: the
        // running poll reads this value from UserDefaults on every tick, so a
        // new delay takes effect on the next one. Syncing would just tear the
        // timer down and restart the wait.
        .onChange(of: autoClearDelay) { _, value in
            let sanitized = Defaults.sanitizedClipboardAutoClearDelay(value)
            if sanitized != value { autoClearDelay = sanitized }
        }
        .onChange(of: menuBarPreviewLength) { _, value in
            let sanitized = Defaults.sanitizedClipboardMenuBarPreviewLength(value)
            if sanitized != value { menuBarPreviewLength = sanitized }
        }
    }

    @ViewBuilder
    private func clipboardShortcutSection(history: ClipboardHistoryService) -> some View {
        Section(text.shortcut) {
            Toggle(text.shortcut, isOn: $shortcutEnabled)
                .onChange(of: shortcutEnabled) { _, _ in
                    if AppFeature.clipboardHistory.isAvailable { history.syncHotkey() }
                }
                .disabled(!enabled)
            ShortcutPreferenceRow(role: .clipboard,
                                  isEnabled: enabled && shortcutEnabled,
                                  additionalConflict: WindowLayoutService.shared.shortcutConflictTitle) {
                if AppFeature.clipboardHistory.isAvailable { history.syncHotkey() }
            }
            if enabled, shortcutEnabled, history.shortcutRegistrationFailed {
                Text(l10n.s.shortcutUnavailable)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(text.shortcutCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Not disabled with capture off: the window still opens on the
            // saved items, like the button below.
            Picker(text.historyLayout, selection: $historyLayout) {
                Text(text.historyLayoutList).tag(ClipboardHistoryLayout.list)
                Text(text.historyLayoutCards).tag(ClipboardHistoryLayout.cards)
            }
            .pickerStyle(.segmented)
            Button {
                ClipboardHistoryService.showIfAvailable()
            } label: {
                Label(text.shortcut, systemImage: "doc.on.clipboard")
            }
            .disabled(history.entries.isEmpty)
        }
    }

    @ViewBuilder
    private var clipboardMenuBarPreviewSection: some View {
        Section {
            Toggle(text.menuBarPreview, isOn: $menuBarPreview)
                .disabled(!enabled)
            HStack {
                Text(text.menuBarPreviewLength)
                Spacer()
                TextField("", value: $menuBarPreviewLength, formatter: Self.menuBarPreviewLengthFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .multilineTextAlignment(.trailing)
                Text(text.menuBarPreviewLengthSuffix)
                    .foregroundStyle(.secondary)
            }
            .disabled(!enabled || !menuBarPreview)
            Text(text.menuBarPreviewCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static let menuBarPreviewLengthFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: Defaults.allowedClipboardMenuBarPreviewLengthRange.lowerBound)
        formatter.maximum = NSNumber(value: Defaults.allowedClipboardMenuBarPreviewLengthRange.upperBound)
        formatter.usesGroupingSeparator = false
        return formatter
    }()

    // Never disabled by the capture toggle, unlike the sections above it:
    // emptying the pasteboard is a security setting in its own right, and
    // someone who keeps no history is exactly who reaches for it.
    @ViewBuilder
    private var clipboardAutoClearSection: some View {
        Section {
            HStack {
                Toggle(text.autoClearEnable, isOn: $autoClearOnDelay)
                    .onChange(of: autoClearOnDelay) { _, _ in
                        if AppFeature.clipboardHistory.isAvailable { ClipboardAutoClearService.shared.syncWithPreferences() }
                    }
                TextField("", value: $autoClearDelay, formatter: Self.delayFieldFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .disabled(!autoClearOnDelay)
                Text(text.autoClearSecondsSuffix)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Toggle(text.autoClearOnSleep, isOn: $autoClearOnSleep)
                .onChange(of: autoClearOnSleep) { _, _ in
                    if AppFeature.clipboardHistory.isAvailable { ClipboardAutoClearService.shared.syncWithPreferences() }
                }
            Toggle(text.autoClearOnDisplaySleep, isOn: $autoClearOnDisplaySleep)
                .onChange(of: autoClearOnDisplaySleep) { _, _ in
                    if AppFeature.clipboardHistory.isAvailable { ClipboardAutoClearService.shared.syncWithPreferences() }
                }
            Toggle(text.autoClearOnScreenLock, isOn: $autoClearOnScreenLock)
                .onChange(of: autoClearOnScreenLock) { _, _ in
                    if AppFeature.clipboardHistory.isAvailable { ClipboardAutoClearService.shared.syncWithPreferences() }
                }
            Text(text.autoClearCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static let delayFieldFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: Defaults.allowedClipboardAutoClearDelayRange.lowerBound)
        formatter.maximum = NSNumber(value: Defaults.allowedClipboardAutoClearDelayRange.upperBound)
        formatter.usesGroupingSeparator = false
        return formatter
    }()

    private func clipboardStatsSection(history: ClipboardHistoryService) -> some View {
            Section {
                HStack {
                    Text("\(history.pinnedEntries.count)")
                    Text(text.pinned)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(history.recentEntries.count)")
                    Text(text.recent)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(text.clearRecent) {
                        clearingRequest = ClipboardClearRecentRequest.capture(history.recentEntriesSnapshot)
                    }
                    .disabled(history.recentEntries.isEmpty)
                    .modifier(ClipboardClearRecentConfirmation(request: $clearingRequest))
                }
            }
    }
}
