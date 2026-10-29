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
import AVFoundation
import Combine
import Defaults
import EventKit
import KeyboardShortcuts
import LaunchAtLogin
import LottieUI
import Sparkle
import SwiftUI
import SwiftUIIntrospect
import UniformTypeIdentifiers

// Extracted from SettingsView.swift, originally created by
// Richard Kunkli on 07/08/2024. Behaviour unchanged.

struct CalendarSettings: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.showCalendar) var showCalendar: Bool
    @Default(.enableReminderLiveActivity) var enableReminderLiveActivity
    @Default(.reminderPresentationStyle) var reminderPresentationStyle
    @Default(.reminderLeadTime) var reminderLeadTime
    @Default(.reminderSneakPeekDuration) var reminderSneakPeekDuration
    @Default(.hideAllDayEvents) var hideAllDayEvents
    @Default(.hideCompletedReminders) var hideCompletedReminders
    @Default(.showFullEventTitles) var showFullEventTitles
    @Default(.autoScrollToNextEvent) var autoScrollToNextEvent
    @Default(.enableThirdPartyCalendarApp) private var enableThirdPartyCalendarApp
    @Default(.selectedCalendarApp) private var selectedCalendarApp
    @Default(.fantasticalDefaultView) private var fantasticalDefaultView

    private func highlightID(_ title: String) -> String {
        SettingsTab.calendar.highlightID(for: title)
    }

    var body: some View {
        Form {
            if !calendarManager.hasCalendarAccess || !calendarManager.hasReminderAccess {
                Text("Calendar or Reminder access is denied. Please enable it in System Settings.")
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding()

                HStack {
                    Button("Request Access") {
                        Task {
                            await calendarManager.checkCalendarAuthorization()
                            await calendarManager.checkReminderAuthorization()
                        }
                    }
                    .buttonStyle(AnchorButtonStyle(prominent: true))

                    Button("Open System Settings") {
                        if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(settingsURL)
                        }
                    }
                }
            } else {
                // Permissions status
                Section(header: Text("Permissions")) {
                    HStack {
                        Text("Calendars")
                        Spacer()
                        Text(statusText(for: calendarManager.calendarAuthorizationStatus))
                            .foregroundColor(color(for: calendarManager.calendarAuthorizationStatus))
                    }
                    HStack {
                        Text("Reminders")
                        Spacer()
                        Text(statusText(for: calendarManager.reminderAuthorizationStatus))
                            .foregroundColor(color(for: calendarManager.reminderAuthorizationStatus))
                    }
                }

                Section(header: Text("Calendar Glance")) {
                    Defaults.Toggle(key: .showCalendar) {
                        Text("Show calendar")
                    }
                    .settingsHighlight(id: highlightID("Show calendar"))
                }

                if showCalendar {
                    Section(header: Text("Event List")) {
                        Toggle("Hide completed reminders", isOn: $hideCompletedReminders)
                            .settingsHighlight(id: highlightID("Hide completed reminders"))
                        Toggle("Show full event titles", isOn: $showFullEventTitles)
                            .settingsHighlight(id: highlightID("Show full event titles"))
                        Toggle("Auto-scroll to next event", isOn: $autoScrollToNextEvent)
                            .settingsHighlight(id: highlightID("Auto-scroll to next event"))
                    }

                    Section(header: Text("All-Day Events")) {
                        Toggle("Hide all-day events", isOn: $hideAllDayEvents)
                            .settingsHighlight(id: highlightID("Hide all-day events"))

                        Text("Turn this off to include all-day entries in the notch calendar and reminder live activity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section(header: Text("Reminder Live Activity")) {
                    Defaults.Toggle(key: .enableReminderLiveActivity) {
                        Text("Enable reminder live activity")
                    }
                    .settingsHighlight(id: highlightID("Enable reminder live activity"))

                    if enableReminderLiveActivity {
                        Picker("Countdown style", selection: $reminderPresentationStyle) {
                            ForEach(ReminderPresentationStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .settingsHighlight(id: highlightID("Countdown style"))

                        HStack {
                            Text("Notify before")
                            Slider(
                                value: Binding(
                                    get: { Double(reminderLeadTime) },
                                    set: { reminderLeadTime = Int($0) }
                                ),
                                in: 1...60,
                                step: 1
                            )
                            Text("\(reminderLeadTime) min")
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }

                        HStack {
                            Text("Sneak peek duration")
                            Slider(
                                value: $reminderSneakPeekDuration,
                                in: 3...20,
                                step: 1
                            )
                            Text("\(Int(reminderSneakPeekDuration)) s")
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }

                Section {
                    Button {
                        SettingsWindowController.shared.showWindow(tab: .lockScreen,
                            highlightID: SettingsTab.lockScreen.highlightID(for: "Show next calendar event"))
                    } label: {
                        Label("Customize lock screen calendar and reminders…", systemImage: "lock.laptopcomputer")
                    }
                    .settingsHighlight(id: highlightID("Customize lock screen calendar and reminders"))
                } header: {
                    Text("Lock screen")
                }

                // MARK: - Third-party Calendar Integration
                Section {
                    Defaults.Toggle(key: .enableThirdPartyCalendarApp) {
                        HStack {
                            Image(systemName: "ellipsis.calendar")
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                            Text("Enable third-party calendar app launch")
                        }
                    }
                    .settingsHighlight(id: highlightID("Enable third-party calendar app launch"))
                    
                    if enableThirdPartyCalendarApp {
                        Picker("Calendar App", selection: $selectedCalendarApp) {
                            ForEach(ThirdPartyCalendarApp.allCases) { app in
                                HStack {
                                    AppIconImage(
                                        bundleIdentifiers: app.bundleIdentifiers,
                                        symbolFallback: app.fallbackIconName,
                                        symbolColor: app.fallbackIconColor
                                    )
                                    Text(app.displayName)
                                }
                                .tag(app)
                            }
                        }
                        .settingsHighlight(id: highlightID("Calendar App"))
                        
                        if selectedCalendarApp == .fantastical {
                            Picker("Default View", selection: $fantasticalDefaultView) {
                                ForEach(FantasticalViewStyle.allCases, id: \.self) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                            .settingsHighlight(id: highlightID("Fantastical Default View"))
                        }
                    }
                } header: {
                    Text("Third-party Calendar Integration")
                } footer: {
                    Text("When enabled, clicking on calendar events will open the selected third-party calendar app instead of Apple Calendar.")
                }

                if showCalendar {
                    Section(header: Text("Select Calendars")) {
                        let grouped = Dictionary(grouping: calendarManager.allCalendars, by: \.accountName)
                        let sortedAccounts = grouped.keys.sorted()

                        ForEach(sortedAccounts, id: \.self) { account in
                            let accountCalendars = grouped[account] ?? []
                            let allAccountSelected = accountCalendars.allSatisfy { calendarManager.getCalendarSelected($0) }

                            Section(header: HStack {
                                Text(account)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { allAccountSelected },
                                    set: { isSelected in
                                        Task {
                                            await calendarManager.setCalendarsSelected(accountCalendars, isSelected: isSelected)
                                        }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(AnchorToggleStyle())
                                .controlSize(.mini)
                            }) {
                                ForEach(accountCalendars, id: \.id) { calendar in
                                    Toggle(isOn: Binding(
                                        get: { calendarManager.getCalendarSelected(calendar) },
                                        set: { isSelected in
                                            Task {
                                                await calendarManager.setCalendarSelected(calendar, isSelected: isSelected)
                                            }
                                        }
                                    )) {
                                        HStack(spacing: 8) {
                                            Circle()
                                                .fill(Color(calendar.color))
                                                .frame(width: 8, height: 8)
                                            Text(calendar.title)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            calendarManager.refreshAuthorizationStatus()
        }
        .navigationTitle("Calendar")
    }

    private func statusText(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess, .authorized: return String(localized: "Full Access")
        case .writeOnly: return String(localized: "Write Only")
        case .denied: return String(localized: "Denied")
        case .restricted: return String(localized: "Restricted")
        case .notDetermined: return String(localized: "Not Determined")
        @unknown default: return String(localized: "Unknown")
        }
    }

    private func color(for status: EKAuthorizationStatus) -> Color {
        switch status {
        case .fullAccess, .authorized: return .green
        case .writeOnly: return .yellow
        case .denied, .restricted: return .red
        case .notDetermined: return .secondary
        @unknown default: return .secondary
        }
    }
}
