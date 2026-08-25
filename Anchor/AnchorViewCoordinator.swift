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

import Combine
import Defaults
import SwiftUI

enum SneakContentType: Equatable {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
    case timer
    case reminder
    case recording
    case doNotDisturb
    case bluetoothAudio
    case privacy
    case lockScreen
    case capsLock
    case claudeUsage
    case eyeBreak
}

extension SneakContentType {
    static func == (lhs: SneakContentType, rhs: SneakContentType) -> Bool {
        switch (lhs, rhs) {
        case (.brightness, .brightness),
             (.volume, .volume),
             (.backlight, .backlight),
             (.music, .music),
             (.mic, .mic),
             (.battery, .battery),
             (.download, .download),
             (.timer, .timer),
             (.reminder, .reminder),
             (.recording, .recording),
             (.doNotDisturb, .doNotDisturb),
             (.bluetoothAudio, .bluetoothAudio),
             (.privacy, .privacy),
             (.lockScreen, .lockScreen),
             (.capsLock, .capsLock),
             (.claudeUsage, .claudeUsage),
             (.eyeBreak, .eyeBreak):
            return true
        default:
            return false
        }
    }
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
    var title: String = ""
    var subtitle: String = ""
    var accentColor: Color?
    var styleOverride: SneakPeekStyle? = nil
    var targetScreenName: String? = nil
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
    var autoHideDuration: TimeInterval? = nil
}

class AnchorViewCoordinator: ObservableObject {
    static let shared = AnchorViewCoordinator()
    private var cancellables = Set<AnyCancellable>()
    private var hoverOpenSuppressedUntil: Date = .distantPast
    
    private static let tabOrder: [NotchViews] = [.home, .timer, .notes, .clipboard, .terminal]
    
    /// Direction of the most recent tab switch (true = forward/right, false = backward/left)
    @Published var tabSwitchForward: Bool = true
    
    @Published var currentView: NotchViews = .home {
        didSet {
            if Defaults[.enableMinimalisticUI] && currentView != .home {
                currentView = .home
                return
            }
            // Track direction before SwiftUI re-renders
            let oldIdx = Self.tabOrder.firstIndex(of: oldValue) ?? 0
            let newIdx = Self.tabOrder.firstIndex(of: currentView) ?? 0
            tabSwitchForward = newIdx >= oldIdx
        }
    }
    
    @Published var statsSecondRowExpansion: CGFloat = 1
    @Published var notesLayoutState: NotesLayoutState = .list
    
    
    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("showWhatsNew") var showWhatsNew: Bool = true
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("timerLiveActivityEnabled") var timerLiveActivityEnabled: Bool = true

    @Default(.enableTimerFeature) private var enableTimerFeature
    @Default(.timerDisplayMode) private var timerDisplayMode
    
    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                openLastTabByDefault = false
                currentView = .home
            }
        }
    }
    
    @AppStorage("openLastTabByDefault") var openLastTabByDefault: Bool = false {
        didSet {
            if openLastTabByDefault {
                alwaysShowTabs = true
            }
        }
    }
    
    @AppStorage("hudReplacement") var hudReplacement: Bool = true
    
    @AppStorage("preferred_screen_name") var preferredScreen = NSScreen.main?.localizedName ?? "Unknown" {
        didSet {
            selectedScreen = preferredScreen
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }
    
    @Published var selectedScreen: String = NSScreen.main?.localizedName ?? "Unknown"

    @Published var optionKeyPressed: Bool = true
    
    private init() {
        selectedScreen = preferredScreen
        Defaults.publisher(.timerDisplayMode)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.handleTimerDisplayModeChange(change.newValue)
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableTimerFeature)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.handleTimerFeatureToggle(change.newValue)
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableMinimalisticUI)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.handleMinimalisticModeChange(change.newValue)
            }
            .store(in: &cancellables)




        // Observe all tab-affecting settings to enforce minimum notch width
        Publishers.MergeMany(
            Defaults.publisher(.showStandardMediaControls).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.showCalendar).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableTimerFeature).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.timerDisplayMode).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableNotes).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableClipboardManager).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.clipboardDisplayMode).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableTerminalFeature).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableMinimalisticUI).map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
        .sink { _ in
            enforceMinimumNotchWidth()
        }
        .store(in: &cancellables)

        // Enforce minimum width on launch for existing configurations
        enforceMinimumNotchWidth()
    }

    var isHoverOpenSuppressed: Bool {
        Date() < hoverOpenSuppressedUntil
    }

    func suppressHoverOpen(for duration: TimeInterval = 0.35) {
        hoverOpenSuppressedUntil = Date().addingTimeInterval(max(0, duration))
    }


    private func handleTimerDisplayModeChange(_ mode: TimerDisplayMode) {
        guard mode == .popover, currentView == .timer else { return }
        withAnimation(.smooth) {
            currentView = .home
        }
    }

    private func handleTimerFeatureToggle(_ isEnabled: Bool) {
        guard !isEnabled, currentView == .timer else { return }
        withAnimation(.smooth) {
            currentView = .home
        }
    }

    private func handleMinimalisticModeChange(_ isEnabled: Bool) {
        guard isEnabled else { return }
        if currentView != .home {
            withAnimation(.smooth) {
                currentView = .home
            }
        }
    }



    
    func toggleSneakPeek(
        status: Bool,
        type: SneakContentType,
        duration: TimeInterval = 1.5,
        value: CGFloat = 0,
        icon: String = "",
        title: String = "",
        subtitle: String = "",
        accentColor: Color? = nil,
        styleOverride: SneakPeekStyle? = nil,
        onScreen targetScreen: NSScreen? = nil
    ) {
        let resolvedDuration: TimeInterval
        switch type {
        case .timer:
            resolvedDuration = 10
        case .reminder:
            resolvedDuration = Defaults[.reminderSneakPeekDuration]
        case .claudeUsage:
            // Long enough to read a reset time; short enough not to sit on the
            // notch. The countdown itself lives in the live activity, not here.
            resolvedDuration = 6
        default:
            resolvedDuration = duration
        }
        sneakPeekDuration = resolvedDuration
        // Not a system HUD event — it must show whether or not the user has the
        // volume/brightness HUD turned on, exactly as .timer and .reminder do.
        let bypassedTypes: [SneakContentType] = [.music, .timer, .reminder, .bluetoothAudio, .claudeUsage, .eyeBreak]
        
        
        if !bypassedTypes.contains(type) && !Defaults[.enableSystemHUD] {
            return
        }
        DispatchQueue.main.async {
            // Single write so `sneakPeek.didSet` (which schedules the auto-hide)
            // fires once, not once per field — the per-field writes raced the hide
            // Task and could wedge `show == true` with no pending hide.
            var updated = self.sneakPeek
            updated.show = status
            updated.type = type
            updated.value = value
            updated.icon = icon
            updated.title = title
            updated.subtitle = subtitle
            updated.accentColor = accentColor
            updated.styleOverride = styleOverride
            updated.targetScreenName = targetScreen?.localizedName
            withAnimation(.smooth(duration: 0.3)) {
                self.sneakPeek = updated
            }
        }
    }
    
    private var sneakPeekDuration: TimeInterval = 1.5
    private var sneakPeekTask: Task<Void, Never>?

    // Helper function to manage sneakPeek timer using Swift Concurrency
    private func scheduleSneakPeekHide(after duration: TimeInterval) {
        sneakPeekTask?.cancel()
        
        // Don't schedule auto-hide if duration is infinite (for persistent indicators like Caps Lock)
        guard duration.isFinite else { return }

        sneakPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    // Hide the sneak peek with the correct type that was showing
                    self.toggleSneakPeek(status: false, type: self.sneakPeek.type)
                    self.sneakPeekDuration = 1.5
                }
            }
        }
    }
    
    @Published var sneakPeek: sneakPeek = .init() {
        didSet {
            if sneakPeek.show {
                scheduleSneakPeekHide(after: sneakPeekDuration)
            } else {
                sneakPeekTask?.cancel()
            }
        }
    }
    
    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium,
        autoHideDuration: TimeInterval? = nil
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
                self.expandingView.autoHideDuration = autoHideDuration
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?
    
    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                // Only auto-hide for battery, not for downloads (DownloadManager handles that)
                if expandingView.type != .download {
                    let duration = expandingView.autoHideDuration ?? 3
                    expandingViewTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(duration))
                        guard let self = self, !Task.isCancelled else { return }
                        self.toggleExpandingView(status: false, type: .battery)
                    }
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }

    
    func showEmpty() {
        currentView = .home
    }
    
    // MARK: - Clipboard Management
    @Published var shouldToggleClipboardPopover: Bool = false
    
    func toggleClipboardPopover() {
        // Toggle the published property to trigger UI updates
        shouldToggleClipboardPopover.toggle()
    }
}
