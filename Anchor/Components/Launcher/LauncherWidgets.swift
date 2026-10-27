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
import AnchorUtilities
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
    let profileID: String
    @AppStorage("launcherWidgetProfiles") private var profileData = Data()
    @State private var editing = false
    @State private var ready = false
    private var profile: LauncherWidgetProfile { .load(profileData, screen: profileID) }
    private var enabled: [String] {
        profile.order.filter { id in
            switch id {
            case "clock": return showClock
            case "weather": return showWeather
            case "calendar": return showCalendar
            case "reminders": return showReminders
            case "music": return showVinyl
            default: return false
            }
        }
    }

    private func update(_ change: (inout LauncherWidgetProfile) -> Void) {
        var value = profile
        change(&value)
        profileData = value.saving(in: profileData, screen: profileID)
    }

    private func move(_ id: String, by offset: Int) {
        guard let visibleIndex = enabled.firstIndex(of: id),
              enabled.indices.contains(visibleIndex + offset),
              let from = profile.order.firstIndex(of: id),
              let to = profile.order.firstIndex(of: enabled[visibleIndex + offset]) else { return }
        update { $0.order.swapAt(from, to) }
    }

    @ViewBuilder private func widget(_ id: String) -> some View {
        switch id {
        case "clock": LauncherClockWidget()
        case "weather": LauncherWeatherWidget()
        case "calendar": LauncherCalendarWidget()
        case "reminders": LauncherRemindersWidget()
        default: LauncherVinylWidget(size: musicSize(id))
        }
    }

    private func musicSize(_ id: String) -> LauncherPlayerWidget.Size {
        guard let size = profile.sizes[id] else { return Defaults[.launcherWidgetSize] }
        return size == 0 ? .compact : size == 2 ? .wide : .regular
    }

    @Default(.launcherShowClockWidget) private var showClock
    @Default(.launcherShowWeatherWidget) private var showWeather
    @Default(.launcherShowVinylWidget) private var showVinyl
    @Default(.launcherShowCalendarWidget) private var showCalendar
    @Default(.launcherShowRemindersWidget) private var showReminders

    var anyEnabled: Bool { showClock || showWeather || showVinyl || showCalendar || showReminders }

    var body: some View {
        if anyEnabled {
            VStack(alignment: .trailing, spacing: 4) {
                Button(editing ? "Done" : "Edit widgets") { editing.toggle() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                ScrollView(.vertical) {
                    LauncherWidgetFlow(spacing: 16) {
                        ForEach(enabled, id: \.self) { id in
                            VStack(spacing: 6) {
                                if ready {
                                    widget(id)
                                        .environment(\.launcherWidgetWidth, width(id) - 28)
                                } else {
                                    AnchorCorners.rectangle(cornerRadius: 16)
                                        .fill(.quaternary).frame(width: width(id), height: 90)
                                }
                                if editing {
                                    HStack {
                                        Button { move(id, by: -1) } label: { Image(systemName: "arrow.left") }
                                            .disabled(enabled.first == id).accessibilityLabel("Move widget left")
                                        Menu("Size") {
                                            ForEach(0..<3) { size in
                                                Button(["Compact", "Regular", "Wide"][size]) {
                                                    update { $0.sizes[id] = size }
                                                }
                                            }
                                        }
                                        Button { move(id, by: 1) } label: { Image(systemName: "arrow.right") }
                                            .disabled(enabled.last == id).accessibilityLabel("Move widget right")
                                    }.controlSize(.small)
                                }
                            }
                        }
                    }
                }.scrollIndicators(.never)
                if editing { Text("Layout saved for this display").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.bottom, 12)
            .task {
                // Let search and app tiles present before constructing media/EventKit views.
                await Task.yield()
                guard !Task.isCancelled else { return }
                ready = true
            }
        }
    }

    private func width(_ id: String) -> CGFloat {
        switch profile.sizes[id] ?? 1 {
        case 0: return 190
        case 2: return 330
        default: return 246
        }
    }
}

/// Wrap saved widget widths into rows instead of clipping the last widget off
/// screen. The same stored order and size choices work in both launcher modes.
private struct LauncherWidgetFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        return arrange(subviews, width: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(subviews, width: bounds.width).positions
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + positions[index].x,
                                     y: bounds.minY + positions[index].y),
                          anchor: .topLeading, proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, positions: [CGPoint]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var positions: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), positions)
    }
}

private struct LauncherCalendarWidget: View {
    @Environment(\.launcherWidgetWidth) private var width
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
                        HStack {
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
                        if let url = event.conferenceURL {
                            Button("Join") { NSWorkspace.shared.open(url) }
                                .buttonStyle(AnchorButtonStyle()).controlSize(.small)
                                .help("Join \(event.title)")
                        }
                        }
                    }
                }
            }
            .frame(width: width, alignment: .leading)
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
    @Environment(\.launcherWidgetWidth) private var width
    @State private var saving = false
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
                if let error = reminders.errorMessage {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
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
                    .disabled(saving || !reminders.hasAccess || newTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Add reminder")
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .task { await reminders.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await reminders.refresh(force: true) }
        }
    }

    private func addTask() {
        guard reminders.hasAccess, !saving else { return }
        let title = newTask
        saving = true
        Task {
            if await reminders.add(title), newTask == title { newTask = "" }
            saving = false
        }
    }
}

/// A widget's shared shell, so the three look like one set.
private struct WidgetCard<Content: View>: View {
    @Environment(\.launcherWidgetWidth) private var width
    var onTap: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: width + 28, alignment: .leading)
            .frame(minHeight: 86, alignment: .leading)
            .background(AnchorSurface(radius: 18))
            .anchorCornerContainer(radius: 18)
            .overlay {
                AnchorCorners.rectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(AnchorCorners.rectangle(cornerRadius: 16))
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
    var size: LauncherPlayerWidget.Size = .regular
    var body: some View {
        LauncherPlayerWidget(size: size, onOpen: {
            Defaults[.enablePlayerWidget] = true
            PlayerWindowManager.shared.sync()
        })
        .help("Open the desktop player")
    }
}
