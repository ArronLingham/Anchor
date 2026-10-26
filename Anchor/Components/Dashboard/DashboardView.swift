import AppKit
import AnchorUtilities
import Defaults
import SwiftUI

struct DashboardView: View {
    let hardware: DashboardHardwareState
    @State private var section: DashboardSection = .overview

    @AppStorage("AnchorDashboardLayout") private var savedLayout = Data()
    @State private var isCustomizing = false
    private var layout: DashboardLayout { DashboardLayout.load(savedLayout) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "mountain.2.fill").font(.system(size: 16, weight: .medium))
                    Text("Anchor").font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    DashboardBatteryBadge()
                    Button { UtilityWorkspace.shared.showLibrary() } label: {
                        Label("Features & Tools", systemImage: "square.grid.2x2")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    Button { isCustomizing.toggle() } label: {
                        Label("Customize", systemImage: "square.grid.2x2")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $isCustomizing, arrowEdge: .bottom) { customization }
                    .help("Choose cards for this Dashboard tab")
                    Button { SettingsWindowController.shared.showWindow() } label: {
                        Image(systemName: "gearshape").font(.system(size: 15)).padding(8)
                    }
                        .buttonStyle(.plain)
                        .help("Open settings")
                }.padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 12)
                sectionPicker.padding(.horizontal, 28)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        DashboardNotice(hardware: hardware)
                        sectionContent(isWide: geometry.size.width >= 860)
                    }
                    .padding(.horizontal, 28).padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .id(section)
            }
        }
        .background(AnchorCanvas().ignoresSafeArea())
        .frame(minWidth: 620, minHeight: 540)
        .anchorTheme()
    }

    private var sectionPicker: some View {
        HStack(spacing: 24) {
            ForEach(DashboardSection.allCases) { item in
                Button { section = item } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 12, weight: section == item ? .semibold : .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(section == item ? AnchorDesign.text : AnchorDesign.muted)
                        .overlay(alignment: .bottom) {
                            if section == item {
                                Rectangle().fill(AnchorDesign.accent).frame(height: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
        }
        .background(alignment: .bottom) { DashboardDivider() }
    }

    private var customization: some View {
        DashboardCustomizationView(section: section, savedLayout: $savedLayout) { isCustomizing = false }
    }

    @ViewBuilder private func sectionContent(isWide: Bool) -> some View {
        let rows = layout.rows(in: section)
        if rows.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
                Text("Make this space yours").font(.headline)
                Button("Choose Dashboard cards") { isCustomizing = true }
            }.frame(maxWidth: .infinity).padding(.vertical, 70)
        } else {
            ForEach(rows) { row in
                if row.id != rows.first?.id { DashboardDivider() }
                if row.cards.count == 2 {
                    DashboardColumns(isWide: isWide) {
                        card(row.cards[0])
                    } trailing: {
                        card(row.cards[1])
                    }
                } else {
                    card(row.cards[0])
                }
            }
        }
    }

    private func card(_ card: DashboardCard) -> some View {
        DashboardSectionContent(card.title, symbol: card.symbol) {
            switch card {
            case .tasks:
                DashboardTaskCard(showsAll: section == .productivity) { section = .productivity }
            case .nowPlaying: DashboardMediaCard(expanded: section == .media)
            case .focus: DashboardTimerCard()
            case .upcoming: DashboardCalendarCard()
            case .shelf: ShelfWorkspaceView(seamless: true)
            case .clipboard: DashboardClipboardCard()
            case .quicklinks: DashboardQuicklinksCard()
            case .appAudio: DashboardAppAudioCard()
            case .soundDisplay: DashboardSoundDisplayCard(hardware: hardware)
            case .quickControls: DashboardToolsCard(hardware: hardware)
            case .featureFavorites: UtilityFavoritesView()
            }
        }
    }
}

// Keep frequently changing hardware/battery observations at the leaves. A
// volume notification must not invalidate every card in the Dashboard.
private struct DashboardBatteryBadge: View {
    @ObservedObject private var battery = BatteryStatusViewModel.shared
    var body: some View {
        Label("\(Int(battery.levelBattery))%", systemImage: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent")
            .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(AnchorDesign.muted)
    }
}

private struct DashboardDivider: View {
    var body: some View {
        Rectangle().fill(AnchorDesign.edge).frame(height: 1).accessibilityHidden(true)
    }
}

private struct DashboardNotice: View {
    @ObservedObject var hardware: DashboardHardwareState
    var body: some View {
        if let message = hardware.message {
            HStack {
                Text(message).font(.callout)
                Spacer()
                Button { hardware.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }.padding(12).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct DashboardSectionContent<Content: View>: View {
    let title: String; let symbol: String; @ViewBuilder let content: () -> Content
    init(_ title: String, symbol: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.symbol = symbol; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }.foregroundStyle(AnchorDesign.muted)
            content()
        }.padding(.vertical, 26).frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct DashboardColumns<Leading: View, Trailing: View>: View {
    let isWide: Bool
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        if isWide {
            HStack(alignment: .top, spacing: 28) {
                leading().frame(maxWidth: .infinity, alignment: .topLeading)
                Divider().overlay(AnchorDesign.edge)
                trailing().frame(maxWidth: .infinity, alignment: .topLeading)
            }.fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 0) {
                leading()
                DashboardDivider()
                trailing()
            }
        }
    }
}

private struct DashboardSoundDisplayCard: View {
    @ObservedObject var hardware: DashboardHardwareState
    @ObservedObject private var monitors = ExternalMonitorController.shared
    @ObservedObject private var routes = AudioRouteManager.shared
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { hardware.toggleMute() } label: { Image(systemName: hardware.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                    .buttonStyle(.borderless).disabled(!hardware.canMute).help(hardware.isMuted ? "Unmute" : "Mute")
                Slider(value: Binding(get: { hardware.volume }, set: hardware.setVolume), in: 0...1)
                    .disabled(!hardware.canSetVolume).accessibilityLabel("Output volume")
                Text("\(Int(hardware.volume * 100))%").font(.caption.monospacedDigit()).frame(width: 38)
            }
            Picker("Output", selection: Binding(get: { routes.activeDeviceID }, set: { id in
                if let device = routes.devices.first(where: { $0.id == id }) { routes.select(device: device) }
            })) { ForEach(routes.devices) { device in Text(device.name).tag(device.id) } }
            Divider()
            Picker("Display", selection: $hardware.selectedDisplayID) {
                ForEach(hardware.displays) { display in Text(display.name).tag(display.id) }
            }
            if hardware.canSetBrightness {
                HStack {
                    Image(systemName: "sun.max")
                    Slider(value: Binding(get: { hardware.brightness }, set: hardware.setBrightness), in: 0...1).accessibilityLabel("Display brightness")
                    Text("\(Int(hardware.brightness * 100))%").font(.caption.monospacedDigit()).frame(width: 38)
                }
            } else {
                Button("Open display controls…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                }.font(.caption)
                Text("This display does not expose brightness through macOS.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Disconnect External Monitors") { monitors.disconnectExternalMonitors() }
                Button("Reconnect Monitors") { monitors.reconnectMonitors() }
            }.disabled(monitors.isChangingDisplays)
            Text(monitors.displayControlMessage.isEmpty ? "Stops the display signal while the cable stays plugged in." : monitors.displayControlMessage)
                .font(.caption).foregroundStyle(.secondary)
            if !hardware.canSetVolume { Text("Volume is managed by the selected output device.").font(.caption).foregroundStyle(.secondary) }
        }.controlSize(.small)
    }
}

private struct DashboardMediaCard: View {
    @ObservedObject private var music = MusicManager.shared
    @Default(.enablePlayerWidget) private var playerVisible
    var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 22 : 16) {
            HStack(spacing: expanded ? 24 : 14) {
                Image(nsImage: music.albumArt).resizable().scaledToFill()
                    .frame(width: expanded ? 144 : 64, height: expanded ? 144 : 64)
                    .clipShape(RoundedRectangle(cornerRadius: expanded ? 16 : 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(music.songTitle.isEmpty ? "Nothing playing" : music.songTitle)
                        .font(.system(size: expanded ? 26 : 16, weight: .semibold, design: .rounded)).lineLimit(2)
                    Text(music.artistName.isEmpty ? "Start music in your favorite player" : music.artistName)
                        .font(.system(size: expanded ? 14 : 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            if music.songDuration.isFinite && music.songDuration > 0 && !music.isLiveStream {
                Slider(value: Binding(get: { music.elapsedTime.isFinite ? min(music.songDuration, max(0, music.elapsedTime)) : 0 },
                                      set: { music.seek(to: $0) }), in: 0...music.songDuration).accessibilityLabel("Playback position")
            }
            HStack {
                HStack(spacing: 14) {
                Button { music.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundStyle(music.isShuffled ? Color.accentColor : .secondary) }.help("Shuffle")
                Button { music.previousTrack() } label: { Image(systemName: "backward.fill") }.help("Previous track")
                Button { music.playPause() } label: { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").font(.title2) }.help(music.isPlaying ? "Pause" : "Play")
                Button { music.nextTrack() } label: { Image(systemName: "forward.fill") }.help("Next track")
                Button { music.toggleRepeat() } label: { Image(systemName: music.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(music.repeatMode == .off ? Color.secondary : .accentColor) }.help("Repeat")
                }.buttonStyle(AnchorButtonStyle()).disabled(!music.hasActiveSession)
                Spacer(minLength: 12)
                if expanded {
                    Button { openFullScreen() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }.help("Open full-screen player")
                }
                playerMenu
            }
        }
    }

    private var playerMenu: some View {
        Menu("Player") {
                Button("Open player", systemImage: "rectangle.on.rectangle") { setPlayerVisible(true) }
                    .disabled(playerVisible)
                Button("Hide player", systemImage: "rectangle.slash") { hidePlayer() }
                    .disabled(!playerVisible && !DesktopFullScreenController.shared.isOpen)
                Divider()
                Button("Open full-screen player", systemImage: "arrow.up.left.and.arrow.down.right", action: openFullScreen)
            }
            .font(.caption)
    }

    private func openFullScreen() {
        setPlayerVisible(true)
        DesktopFullScreenController.shared.open()
    }

    private func setPlayerVisible(_ visible: Bool) {
        Defaults[.enablePlayerWidget] = visible
        PlayerWindowManager.shared.sync()
    }

    private func hidePlayer() {
        DesktopFullScreenController.shared.close()
        setPlayerVisible(false)
    }
}

private struct DashboardTimerCard: View {
    @ObservedObject private var timer = TimerManager.shared
    @ObservedObject private var focus = FocusSessionManager.shared
    @Default(.enableTimerFeature) private var enabled
    @State private var mode = "focus"
    var body: some View {
        VStack(spacing: 6) {
            if !enabled {
                Button("Enable timers") { enabled = true }
            } else {
                Picker("Timer workspace", selection: $mode) { Text("Focus").tag("focus"); Text("Timer").tag("timer") }.pickerStyle(.segmented)
                if mode == "focus" { FocusSessionView() }
                else if timer.isTimerActive {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(timer.timerName).font(.headline)
                            Text(timer.formattedTimeRemaining).font(.system(size: 30, design: .rounded)).monospacedDigit()
                        }
                        Spacer()
                        if timer.allowsManualInteraction {
                            Button(timer.isPaused ? "Resume" : "Pause") { timer.isPaused ? timer.resumeTimer() : timer.pauseTimer() }
                            Button("Stop") { timer.forceStopTimer() }
                        } else { Text("Managed by Clock").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 12)
                } else {
                    HStack { ForEach([5, 10, 25], id: \.self) { minutes in
                        Button("\(minutes) min") { timer.startTimer(duration: Double(minutes * 60)) }.buttonStyle(AnchorButtonStyle())
                    } }.padding(.vertical, 18)
                }
            }
        }.onAppear { if timer.isTimerActive && timer.activeSource != .focus { mode = "timer" } }
    }
}

private struct DashboardTaskCard: View {
    @ObservedObject private var todos = TodoManager.shared
    @Default(.todoShowCompleted) private var showCompleted
    @State private var title = ""
    @State private var draftPriority = 0
    var showsAll: Bool
    var onViewAll: (() -> Void)? = nil

    init(showsAll: Bool, onViewAll: (() -> Void)? = nil) {
        self.showsAll = showsAll
        self.onViewAll = onViewAll
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Add a task", text: $title).textFieldStyle(AnchorFieldStyle()).onSubmit(add)
                priorityPicker(selection: $draftPriority, label: "Priority for new task")
                Button(action: add) { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || todos.storageNeedsRecovery)
            }
            if todos.openItems.isEmpty { Text("You’re all caught up.").font(.callout).foregroundStyle(.secondary) }
            ForEach(showsAll ? todos.openItems : Array(todos.openItems.prefix(5))) { item in
                HStack {
                    Button { todos.complete(item) } label: { Image(systemName: "circle") }.buttonStyle(.plain).help("Complete task")
                    Text(item.title).font(.callout).lineLimit(1)
                    Spacer()
                    priorityPicker(selection: Binding(
                        get: { todos.items.first(where: { $0.id == item.id })?.priority ?? item.priority },
                        set: { todos.setPriority($0, for: item) }
                    ), label: "Priority for \(item.title)")
                    if let due = item.dueDate { Text(due, style: .date).font(.caption).foregroundStyle(item.isOverdue ? .red : .secondary) }
                }.contextMenu {
                    Button("Focus on this task") { FocusSessionManager.shared.startFocus(intention: item.title) }
                    Button("Complete") { todos.complete(item) }
                }
            }
            HStack {
                Text("\(todos.openCount) open" + (todos.overdueCount > 0 ? " · \(todos.overdueCount) overdue" : "")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if todos.lastCompletion != nil { Button("Undo completion") { _ = todos.undoLastCompletion() }.font(.caption) }
                if showsAll {
                    Toggle("Completed", isOn: $showCompleted).toggleStyle(.checkbox).font(.caption)
                } else if let onViewAll {
                    Button("View all", action: onViewAll).font(.caption)
                }
            }
            if showsAll && showCompleted {
                if !todos.doneItems.isEmpty {
                    Divider().padding(.vertical, 3)
                    Text("COMPLETED").font(.system(size: 10, weight: .semibold)).foregroundStyle(AnchorDesign.muted)
                    ForEach(todos.doneItems) { item in
                        HStack {
                            Button { todos.toggle(item) } label: { Image(systemName: "checkmark.circle.fill") }.buttonStyle(.plain).help("Reopen task")
                            Text(item.title).font(.callout).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let error = todos.storageError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
    private func priorityPicker(selection: Binding<Int>, label: String) -> some View {
        Menu {
            Picker("Priority", selection: selection) {
                ForEach(0...3, id: \.self) { level in
                    Text(level.todoPriorityLabel).tag(level)
                }
            }.pickerStyle(.inline)
        } label: {
            Label(selection.wrappedValue.todoPriorityLabel,
                  systemImage: selection.wrappedValue == 0 ? "flag" : "flag.fill")
                .font(.caption)
                .foregroundStyle(selection.wrappedValue.todoPriorityColor ?? AnchorDesign.muted)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(label).accessibilityLabel(label)
        .accessibilityValue(selection.wrappedValue.todoPriorityLabel)
        .disabled(todos.storageNeedsRecovery)
    }

    private func add() {
        if todos.add(title, priority: draftPriority) != nil {
            title = ""
            draftPriority = 0
        }
    }
}

private struct DashboardClipboardCard: View {
    @ObservedObject private var clipboard = ClipboardManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(clipboard.clipboardHistory.count) recent copies").font(.title3.bold())
                Spacer()
                Text("\(clipboard.pinnedItems.count) pinned").font(.caption).foregroundStyle(.secondary)
            }
            if clipboard.isCapturePaused { Text("Capture paused").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Open clipboard") { ClipboardPanelManager.shared.showClipboardPanel() }.buttonStyle(AnchorButtonStyle(prominent: true))
                Button(clipboard.isCapturePaused ? "Resume capture" : "Pause capture") { clipboard.setCapturePaused(!clipboard.isCapturePaused) }
            }
        }
    }
}

private struct DashboardCalendarCard: View {
    @ObservedObject private var calendar = CalendarManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let events = calendar.events.filter { !$0.type.isReminder && $0.end > Date() }.sorted { $0.start < $1.start }
            if events.isEmpty { Text("No upcoming events in the current calendar view.").font(.callout).foregroundStyle(.secondary) }
            ForEach(events.prefix(4)) { event in
                HStack {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: event.calendar.color)).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.callout).lineLimit(1)
                        Text(event.start, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = event.conferenceURL { Button("Join") { NSWorkspace.shared.open(url) }.buttonStyle(AnchorButtonStyle()) }
                }
            }
            Button("Open calendar") { DashboardWindowController.openNotch(.home) }.font(.caption)
        }
    }
}

private struct DashboardToolsCard: View {
    let hardware: DashboardHardwareState
    @ObservedObject private var awake = KeepAwakeManager.shared
    @Default(.notchPinnedOpen) private var pinned
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                tool("Launcher", "square.grid.2x2") { LauncherPanelManager.shared.show() }
                tool("Notes", "note.text") { DashboardWindowController.openNotch(.notes) }
                tool("Terminal", "terminal") { DashboardWindowController.openNotch(.terminal) }
                tool("Color picker", "eyedropper") { ColorPickerManager.shared.pick() }
                tool("Appearance", "circle.lefthalf.filled") { hardware.report(QuickToggles.toggleDarkMode()) }
                tool("Lock Mac", "lock") { hardware.report(QuickToggles.lockScreen(source: .dashboard)) }
            }
            HStack {
                Toggle("Keep notch open", isOn: $pinned).toggleStyle(.checkbox)
                Spacer()
                Button(awake.isEnabled ? "Stop keeping awake" : "Keep awake for 1 hour") { awake.toggle() }
                    .tint(awake.isEnabled ? .orange : .accentColor)
            }.font(.caption)
            Menu("Arrange previous app’s window") {
                Button("Left half") { DashboardWindowController.shared.arrangePreviousWindow(.left) }
                Button("Right half") { DashboardWindowController.shared.arrangePreviousWindow(.right) }
                Button("Maximize") { DashboardWindowController.shared.arrangePreviousWindow(.top) }
                Button("Center") { DashboardWindowController.shared.arrangePreviousWindow(.centre) }
            }.font(.caption)
            if let error = awake.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
    private func tool(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct DashboardAppAudioCard: View {
    @ObservedObject private var audio = PerAppAudioManager.shared
    @Default(.enablePerAppAudio) private var enabled
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !enabled { Button("Enable app audio controls") { enabled = true } }
            else if audio.apps.isEmpty { Text("Apps playing audio appear here.").foregroundStyle(.secondary).font(.callout) }
            ForEach(Array(audio.apps.prefix(5))) { app in
                HStack {
                    Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
                    Text(app.name).font(.caption).lineLimit(1).frame(width: 85, alignment: .leading)
                    Slider(value: Binding(get: { Double(audio.volume(for: app)) }, set: { audio.setVolume(Float($0), for: app) }), in: 0...2).accessibilityLabel("Volume for \(app.name)")
                    Button { audio.toggleMute(app) } label: { Image(systemName: audio.state(for: app).isMuted ? "speaker.slash" : "speaker.wave.2") }.buttonStyle(.borderless).help("Mute or unmute \(app.name)")
                }
            }
            if let failure = audio.lastFailure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
    }
}

private struct DashboardQuicklinksCard: View {
    @ObservedObject private var manager = QuicklinkManager.shared
    @State private var query = ""
    @State private var hint: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("g search, gh code, or a URL", text: $query).textFieldStyle(AnchorFieldStyle()).onSubmit(open)
                Button("Go", action: open)
            }
            ForEach(manager.links.filter { $0.isEnabled && !$0.needsQuery }.prefix(4)) { link in
                Button { if let url = link.resolvedURL(query: "") { NSWorkspace.shared.open(url) } } label: { Label(link.title, systemImage: "link") }.buttonStyle(.borderless)
            }
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            Button("Manage quicklinks") { SettingsWindowController.shared.showWindow(tab: .launcher) }.font(.caption)
        }
    }
    private func open() {
        guard let result = manager.searchCommands(query).max(by: { $0.score < $1.score }) else { hint = "Use a saved keyword followed by a search term, or enter a website URL."; return }
        result.command.run(); hint = nil
    }
}

struct DashboardCustomizationView: View {
    let section: DashboardSection
    @Binding var savedLayout: Data
    let onDone: () -> Void
    private var layout: DashboardLayout { DashboardLayout.load(savedLayout) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Customize \(section.title)").font(.headline)
                Spacer()
                Button("Done") { onDone() }.buttonStyle(.borderless)
            }
            Text("Choose the cards shown in this tab.").font(.caption).foregroundStyle(.secondary)
            ForEach(DashboardCard.allCases) { card in
                Toggle(isOn: Binding(
                    get: { layout.cards(in: section).contains(card) },
                    set: { visible in
                        var updated = layout
                        updated.setVisible(visible, card: card, in: section)
                        savedLayout = updated.data
                    }
                )) { Label(card.title, systemImage: card.symbol) }
                .toggleStyle(AnchorToggleStyle())
            }
            Divider()
            Button("Restore defaults for \(section.title)") {
                var updated = layout
                updated.restore(section)
                savedLayout = updated.data
            }.buttonStyle(.borderless)
        }
        .padding(20).frame(width: 300).anchorTheme()
    }

}
