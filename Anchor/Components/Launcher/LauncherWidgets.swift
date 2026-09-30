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

/// The strip of widgets above the launcher grid.
///
/// All three default off — the launcher's job is finding an app, and anything
/// permanently occupying the top of it has to earn the space. Each is a
/// separate toggle for the same reason.
///
/// Nothing here polls. The clock is a `TimelineView`, which the system schedules
/// and stops paying for when the view goes away; weather comes from the
/// snapshot the lock screen already fetches; the record reads `MusicManager`,
/// which is event-driven.
struct LauncherWidgetStrip: View {
    @Default(.launcherShowClockWidget) private var showClock
    @Default(.launcherShowWeatherWidget) private var showWeather
    @Default(.launcherShowVinylWidget) private var showVinyl
    @Default(.launcherShowCalendarWidget) private var showCalendar
    @Default(.launcherShowRemindersWidget) private var showReminders

    var anyEnabled: Bool { showClock || showWeather || showVinyl || showCalendar || showReminders }

    var body: some View {
        if anyEnabled {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    if showClock { LauncherClockWidget() }
                    if showWeather { LauncherWeatherWidget() }
                    if showCalendar { LauncherCalendarWidget() }
                    if showReminders { LauncherRemindersWidget() }
                    if showVinyl { LauncherVinylWidget() }
                }
            }
            .scrollIndicators(.hidden)
            .padding(.top, 2)
            .padding(.bottom, 12)
        }
    }
}

private struct LauncherCalendarWidget: View {
    @ObservedObject private var calendar = CalendarManager.shared

    private var upcoming: [EventModel] {
        calendar.launcherEvents
            .filter { $0.type.isEvent && $0.end >= Date() }
            .sorted { $0.start < $1.start }
            .prefix(2)
            .map { $0 }
    }

    var body: some View {
        WidgetCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Calendar", systemImage: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                if !calendar.hasCalendarAccess {
                    Text("Allow Calendar access in Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if upcoming.isEmpty {
                    Text("No upcoming events")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(upcoming) { event in
                        Button {
                            if let url = event.calendarAppURL() {
                                _ = NSWorkspace.shared.open(url)
                            } else {
                                _ = NSWorkspace.shared.open(
                                    URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 58, alignment: .leading)
                                Text(event.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Open \(event.title) in Calendar")
                    }
                }
            }
            .frame(width: 218, alignment: .leading)
        }
        .task {
            if !calendar.hasCalendarAccess {
                await calendar.checkCalendarAuthorization()
            }
            if calendar.hasCalendarAccess { await calendar.updateLauncherEvents() }
        }
    }
}

private struct LauncherRemindersWidget: View {
    @ObservedObject private var reminders = LauncherAppleReminders.shared
    @State private var newTask = ""

    var body: some View {
        WidgetCard {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Reminders", systemImage: "checklist")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(reminders.items.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !reminders.hasAccess {
                    Text("Allow Reminders access")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if reminders.items.isEmpty {
                    Text("All caught up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(reminders.items.prefix(2))) { item in
                        Button {
                            Task { await reminders.complete(item) }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "circle")
                                Text(item.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Complete \(item.title)")
                    }
                }
                HStack(spacing: 5) {
                    TextField("New reminder", text: $newTask)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .onSubmit(addTask)
                    Button(action: addTask) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(newTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Add reminder")
                }
            }
            .frame(width: 218, alignment: .leading)
        }
        .task { await reminders.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await reminders.refresh(force: true) }
        }
    }

    private func addTask() {
        guard reminders.hasAccess else { return }
        let title = newTask
        newTask = ""
        Task { await reminders.add(title) }
    }
}

/// A widget's shared shell, so the three look like one set.
private struct WidgetCard<Content: View>: View {
    var onTap: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minWidth: 108, minHeight: 62, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { onTap?() }
    }
}

private struct LauncherClockWidget: View {
    var body: some View {
        WidgetCard {
            // Scheduled by the system on the minute rather than ticked by a
            // timer, so an open launcher costs nothing while it sits there.
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LauncherWeatherWidget: View {
    @ObservedObject private var weather = LockScreenWeatherManager.shared
    @State private var didRequest = false

    var body: some View {
        WidgetCard {
            if let snapshot = weather.snapshot {
                HStack(spacing: 10) {
                    Image(systemName: snapshot.symbolName)
                        .font(.system(size: 20))
                        .symbolRenderingMode(.multicolor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.temperatureText)
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                        Text(snapshot.locationName ?? snapshot.description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: "cloud.sun")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                    Text("Weather")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            // Once per appearance, and only if nothing has been fetched — the
            // lock screen shares this manager and may already have a snapshot.
            guard !didRequest, weather.snapshot == nil else { return }
            didRequest = true
            _ = await weather.refresh()
        }
    }
}

/// The record, and a way into the full vinyl player.
///
/// Tapping opens the desktop player rather than duplicating its controls here:
/// the launcher is dismissed by the tap anyway, so a transport built into this
/// card would be gone the moment you used it.
private struct LauncherVinylWidget: View {
    var body: some View {
        LauncherPlayerWidget(onOpen: {
            Defaults[.enablePlayerWidget] = true
            PlayerWindowManager.shared.sync()
        })
        .help("Open the desktop player")
    }
}
