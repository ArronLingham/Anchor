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
import EventKit
import SwiftUI

/// Optional cards and their editor on each Launchpad page.
struct LauncherWidgetShelf: View {
    let profileID: String
    let page: Int
    let appPageCount: Int
    let showCategories: Bool
    var isPageActive = true

    @AppStorage("launcherWidgetProfiles") private var profileData = Data()
    @State private var arranging = false
    @State private var dropTarget: Kind?
    @Default(.launcherShowClockWidget) private var showClock
    @Default(.launcherShowWeatherWidget) private var showWeather
    @Default(.launcherShowCalendarWidget) private var showCalendar
    @Default(.launcherShowRemindersWidget) private var showReminders
    @Default(.launcherShowVinylWidget) private var showMusic
    @Default(.launcherWidgetSize) private var defaultMusicSize

    private typealias Kind = LauncherWidgetProfile.Widget

    private var profile: LauncherWidgetProfile { .load(profileData, screen: profileID) }

    private func isEnabled(_ kind: Kind) -> Bool {
        switch kind {
        case .clock: return showClock
        case .weather: return showWeather
        case .calendar: return showCalendar
        case .reminders: return showReminders
        case .music: return showMusic
        }
    }

    var body: some View {
        let layout = profile
        let enabled = layout.order.compactMap(Kind.init(rawValue:)).filter(isEnabled)
        let visible = enabled.filter { placement(of: $0, in: layout) == page }

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if arranging {
                    Button("Done", action: { arranging = false })
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                }
                editMenu(enabled, layout: layout, hasVisibleWidgets: !visible.isEmpty)
            }

            if !visible.isEmpty {
                LauncherWidgetFlow(spacing: 12) {
                    ForEach(visible) { kind in
                        let size = size(for: kind, in: layout)
                        widgetTile(kind, size: size)
                            .layoutValue(key: LauncherWidgetWidth.self, value: size.width)
                    }
                }
            }
        }
    }

    private func editMenu(_ enabled: [Kind], layout: LauncherWidgetProfile, hasVisibleWidgets: Bool) -> some View {
        Menu {
            Section("Show in Launchpad") {
                ForEach(Kind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { isEnabled(kind) },
                        set: { show in
                            if show {
                                update { $0.pages[kind.rawValue] = page }
                            }
                            Defaults[kind.preference] = show
                        }
                    ))
                }
            }
            if !enabled.isEmpty {
                Section("Layout on This Display") {
                    if hasVisibleWidgets && !arranging {
                        Button("Arrange by Dragging", systemImage: "hand.point.up.left") {
                            arranging = true
                        }
                    }
                    ForEach(enabled) { kind in
                        let currentPage = placement(of: kind, in: layout)
                        let neighbors = enabled.filter { placement(of: $0, in: layout) == currentPage }
                        Menu("\(kind.title) · \(pageTitle(currentPage))") {
                            widgetLayoutMenu(kind, neighbors: neighbors)
                        }
                    }
                }
            }
        } label: {
            Label(
                hasVisibleWidgets ? "Edit Widgets" : "Add Widgets",
                systemImage: hasVisibleWidgets ? "slider.horizontal.3" : "plus"
            )
            .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func widgetLayoutMenu(_ kind: Kind, neighbors: [Kind]) -> some View {
        Picker("Page", selection: Binding(
            get: { placement(of: kind, in: profile) },
            set: { target in update { $0.pages[kind.rawValue] = target } }
        )) {
            if showCategories {
                Text("Categories").tag(LauncherWidgetProfile.categoriesPage)
            }
            ForEach(0..<appPageCount, id: \.self) { target in
                Text(pageTitle(target)).tag(target)
            }
        }
        Picker("Size", selection: Binding(
            get: { size(for: kind, in: profile) },
            set: { size in update { $0.sizes[kind.rawValue] = size.profileValue } }
        )) {
            ForEach(LauncherPlayerWidget.Size.allCases, id: \.self) { size in
                Text(size.label).tag(size)
            }
        }
        if let index = neighbors.firstIndex(of: kind) {
            Button("Move Earlier", systemImage: "arrow.left") {
                move(kind, to: index - 1, in: neighbors)
            }
            .disabled(index == 0)
            Button("Move Later", systemImage: "arrow.right") {
                move(kind, to: index + 1, in: neighbors)
            }
            .disabled(index == neighbors.count - 1)
        }
    }

    private func placement(of kind: Kind, in layout: LauncherWidgetProfile) -> Int {
        layout.page(for: kind, appPageCount: appPageCount, showCategories: showCategories)
    }

    private func pageTitle(_ page: Int) -> String {
        page == LauncherWidgetProfile.categoriesPage
            ? String(localized: "Categories")
            : String(localized: "Apps Page \(page + 1)")
    }

    private func update(_ change: (inout LauncherWidgetProfile) -> Void) {
        let previous = profile
        var value = previous
        change(&value)
        guard value != previous else { return }
        profileData = value.saving(in: profileData, screen: profileID)
    }

    private func move(_ kind: Kind, to index: Int, in visible: [Kind]) {
        guard visible.indices.contains(index) else { return }
        update { $0.swapWidgets(kind, visible[index]) }
    }

    private func size(for kind: Kind, in layout: LauncherWidgetProfile) -> LauncherPlayerWidget.Size {
        switch layout.sizes[kind.rawValue] {
        case 0: return .compact
        case 1: return .regular
        case 2: return .wide
        default: return kind == .music ? defaultMusicSize : .regular
        }
    }

    private func widgetTile(_ kind: Kind, size: LauncherPlayerWidget.Size) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if arranging {
                Label(kind.title, systemImage: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AnchorSurface(radius: 8))
                    .contentShape(Rectangle())
                    .onDrag { LauncherWidgetDrop.itemProvider(for: kind, profileID: profileID) }
                    .help("Drag to another widget or a page marker")
            }
            widget(kind, size: size)
        }
        .overlay {
            if arranging && dropTarget == kind {
                AnchorCorners.rectangle(cornerRadius: 16)
                    .anchorStrokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [LauncherWidgetDrop.type], isTargeted: dropTargetBinding(for: kind)) { providers in
            guard arranging, isPageActive else { return false }
            return LauncherWidgetDrop.accept(providers, profileID: profileID) { dragged in
                guard dragged != kind, isEnabled(dragged) else { return }
                update { layout in
                    guard placement(of: dragged, in: layout) == page,
                          placement(of: kind, in: layout) == page else { return }
                    layout.swapWidgets(dragged, kind)
                }
            }
        }
    }

    private func dropTargetBinding(for kind: Kind) -> Binding<Bool> {
        Binding(
            get: { dropTarget == kind },
            set: { targeted in
                if targeted {
                    dropTarget = kind
                } else if dropTarget == kind {
                    dropTarget = nil
                }
            }
        )
    }

    @ViewBuilder private func widget(_ kind: Kind, size: LauncherPlayerWidget.Size) -> some View {
        switch kind {
        case .clock: LauncherClockWidget(isPageActive: isPageActive)
        case .weather: LauncherWeatherWidget(isPageActive: isPageActive)
        case .calendar: LauncherCalendarWidget(isPageActive: isPageActive)
        case .reminders: LauncherRemindersWidget(isPageActive: isPageActive)
        case .music: LauncherPlayerWidget(size: size, isPageActive: isPageActive, onOpen: {
            Defaults[.enablePlayerWidget] = true
            PlayerWindowManager.shared.sync()
        })
        .help("Open the desktop player")
        }
    }
}

/// The private drag type keeps widget moves out of app and folder drop handlers.
private struct LauncherWidgetDrop: Codable {
    static let type = "com.arronlingham.anchor.launchpad.widget"

    let widget: String
    let profileID: String

    static func itemProvider(for widget: LauncherWidgetProfile.Widget, profileID: String) -> NSItemProvider {
        let payload = Self(widget: widget.rawValue, profileID: profileID)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .ownProcess) { completion in
            do {
                completion(try JSONEncoder().encode(payload), nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
        return provider
    }

    static func accept(
        _ providers: [NSItemProvider],
        profileID: String,
        onMove: @escaping @MainActor (LauncherWidgetProfile.Widget) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) })
        else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data,
                  let payload = try? JSONDecoder().decode(Self.self, from: data),
                  payload.profileID == profileID,
                  let widget = LauncherWidgetProfile.Widget(rawValue: payload.widget)
            else { return }
            Task { @MainActor in onMove(widget) }
        }
        return true
    }
}

extension View {
    func launcherWidgetPageDrop(
        profileID: String,
        page: Int,
        onMove: @escaping () -> Void = {}
    ) -> some View {
        launcherWidgetPageDrop(profileID: profileID, pageAt: { _ in page }, onMove: { _ in onMove() })
    }

    func launcherWidgetPageDrop(
        profileID: String,
        pageAt: @escaping (CGPoint) -> Int,
        onMove: @escaping (Int) -> Void = { _ in }
    ) -> some View {
        modifier(LauncherWidgetPageDropTarget(profileID: profileID, pageAt: pageAt, onMove: onMove))
    }
}

private struct LauncherWidgetPageDropTarget: ViewModifier {
    let profileID: String
    let pageAt: (CGPoint) -> Int
    let onMove: (Int) -> Void

    @AppStorage("launcherWidgetProfiles") private var profileData = Data()
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .background {
                if targeted {
                    Capsule().fill(Color.accentColor.opacity(0.22))
                }
            }
            .onDrop(of: [LauncherWidgetDrop.type], isTargeted: $targeted) { providers, location in
                let page = pageAt(location)
                return LauncherWidgetDrop.accept(providers, profileID: profileID) { widget in
                    guard Defaults[widget.preference] else { return }
                    var profile = LauncherWidgetProfile.load(profileData, screen: profileID)
                    profile.pages[widget.rawValue] = page
                    profileData = profile.saving(in: profileData, screen: profileID)
                    onMove(page)
                }
            }
    }
}

private extension LauncherWidgetProfile.Widget {
    var title: String {
        switch self {
        case .clock: return String(localized: "Clock")
        case .weather: return String(localized: "Weather")
        case .calendar: return String(localized: "Calendar")
        case .reminders: return String(localized: "Reminders")
        case .music: return String(localized: "Now Playing")
        }
    }

    var preference: Defaults.Key<Bool> {
        switch self {
        case .clock: return .launcherShowClockWidget
        case .weather: return .launcherShowWeatherWidget
        case .calendar: return .launcherShowCalendarWidget
        case .reminders: return .launcherShowRemindersWidget
        case .music: return .launcherShowVinylWidget
        }
    }
}

private struct LauncherWidgetWidth: LayoutValueKey {
    static let defaultValue: CGFloat = 220
}

/// Use each card's preferred width when it fits, wrap rows, and constrain any
/// card wider than the viewport. The surrounding page owns vertical scrolling.
private struct LauncherWidgetFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        return CGSize(width: width, height: arrange(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placements = arrange(subviews, width: bounds.width).placements
        for (subview, placement) in zip(subviews, placements) {
            subview.place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: placement.width, height: nil)
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (height: CGFloat, placements: [CGRect]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var placements: [CGRect] = []
        for subview in subviews {
            let cardWidth = min(width, subview[LauncherWidgetWidth.self])
            let cardHeight = subview.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height
            if x > 0 && x + cardWidth > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            placements.append(CGRect(x: x, y: y, width: cardWidth, height: cardHeight))
            x += cardWidth + spacing
            rowHeight = max(rowHeight, cardHeight)
        }
        return (y + rowHeight, placements)
    }
}

private struct LauncherCalendarWidget: View {
    let isPageActive: Bool
    @State private var isVisible = false
    @ObservedObject private var calendar = CalendarManager.shared

    private var upcoming: [EventModel] {
        let now = Date()
        return Array(calendar.launcherEvents.lazy.filter { $0.end >= now }.prefix(2))
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
                        HStack(spacing: 6) {
                            Button {
                                let url = event.calendarAppURL()
                                    ?? URL(fileURLWithPath: "/System/Applications/Calendar.app")
                                NSWorkspace.shared.open(url)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Text(eventDate(event))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help("Open \(event.title) in Calendar")
                            if let url = event.conferenceURL {
                                Button("Join") { NSWorkspace.shared.open(url) }
                                    .buttonStyle(AnchorButtonStyle())
                                    .controlSize(.small)
                                    .help("Join \(event.title)")
                            }
                        }
                    }
                }
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
        .task(id: isPageActive && isVisible) {
            guard isPageActive, isVisible else { return }
            if !calendar.hasCalendarAccess {
                await calendar.checkCalendarAuthorization()
            }
            guard !Task.isCancelled, calendar.hasCalendarAccess else { return }
            await calendar.updateLauncherEvents()
        }
    }

    private func eventDate(_ event: EventModel) -> String {
        if Calendar.current.isDateInToday(event.start) {
            return event.isAllDay ? String(localized: "All day")
                : event.start.formatted(.dateTime.hour().minute())
        }
        if event.isAllDay {
            return event.start.formatted(.dateTime.weekday(.abbreviated).day())
        }
        return event.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

private struct LauncherRemindersWidget: View {
    let isPageActive: Bool
    @State private var isVisible = false
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
        }
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
        .task(id: isPageActive && isVisible) {
            guard isPageActive, isVisible else { return }
            await reminders.refresh()
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                guard !Task.isCancelled else { return }
                await reminders.refresh(force: true)
            }
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

/// Shared padding and surface for the system-information cards.
private struct WidgetCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(AnchorSurface(radius: 16))
            .anchorCornerContainer(radius: 16)
            .overlay {
                AnchorCorners.rectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct LauncherClockWidget: View {
    let isPageActive: Bool
    @State private var isVisible = false

    var body: some View {
        WidgetCard {
            if isPageActive && isVisible {
                TimelineView(.everyMinute) { context in dateView(context.date) }
            } else {
                dateView(.now)
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
    }

    private func dateView(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Clock", systemImage: "clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(date, format: .dateTime.hour().minute())
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LauncherWeatherWidget: View {
    let isPageActive: Bool
    @State private var isVisible = false
    @ObservedObject private var weather = LockScreenWeatherManager.shared
    @State private var consumerID = UUID()

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
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
        .onChange(of: isPageActive && isVisible, initial: true) { _, active in
            if active {
                weather.beginLauncher(consumerID)
            } else {
                weather.endLauncher(consumerID)
            }
        }
        .onDisappear { weather.endLauncher(consumerID) }
    }
}
