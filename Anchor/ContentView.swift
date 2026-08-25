/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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

import AVFoundation
import Combine
import Defaults
import Foundation
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: AnchorViewModel

    @ObservedObject var coordinator = AnchorViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var timerManager = TimerManager.shared
    @ObservedObject var reminderManager = ReminderLiveActivityManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var recordingManager = ScreenRecordingManager.shared
    @ObservedObject var privacyManager = PrivacyIndicatorManager.shared
    @ObservedObject var doNotDisturbManager = DoNotDisturbManager.shared
    @ObservedObject var lockScreenManager = LockScreenManager.shared
    @ObservedObject var capsLockManager = CapsLockManager.shared
    @ObservedObject var dictationManager = DictationManager.shared
    /// Only for `isLiveActivityVisible`, which flips a couple of times per usage
    /// window. The per-second countdown is on `ClaudeUsageManager.live` and is
    /// observed by `ClaudeUsageLiveActivity` alone — never from here.
    @ObservedObject var claudeUsageManager = ClaudeUsageManager.shared
    @ObservedObject var eyeBreakManager = EyeBreakManager.shared
    @State private var downloadManager = DownloadManager.shared
    
    @Default(.enableReminderLiveActivity) var enableReminderLiveActivity
    @Default(.showDictationLiveActivity) var showDictationLiveActivity
    @Default(.enableTimerFeature) var enableTimerFeature
    @Default(.timerDisplayMode) var timerDisplayMode
    @Default(.enableHorizontalMusicGestures) var enableHorizontalMusicGestures
    @Default(.reminderPresentationStyle) var reminderPresentationStyle
    @Default(.timerShowsCountdown) var timerShowsCountdown
    @Default(.timerShowsProgress) var timerShowsProgress
    @Default(.timerProgressStyle) var timerProgressStyle
    @Default(.timerIconColorMode) var timerIconColorMode
    @Default(.timerSolidColor) var timerSolidColor
    @Default(.timerPresets) var timerPresets
    @Default(.showCapsLockLabel) var showCapsLockLabel
    @Default(.capsLockIndicatorTintMode) var capsLockTintMode
    @Default(.enableDoNotDisturbDetection) var enableDoNotDisturbDetection
    @Default(.showDoNotDisturbIndicator) var showDoNotDisturbIndicator
    @Default(.enableScreenRecordingDetection) var enableScreenRecordingDetection
    @Default(.enableCapsLockIndicator) var enableCapsLockIndicator
    @Default(.showStandardMediaControls) var showStandardMediaControls
    @Default(.externalDisplayStyle) var externalDisplayStyle
    @Default(.hideNonNotchUntilHover) var hideNonNotchUntilHover
    @Default(.terminalStickyMode) var terminalStickyMode
    
    // Battery settings reactivity
    @Default(.showPowerStatusNotifications) var showPowerStatusNotifications
    @Default(.showChargingBatteryHUD) var showChargingBatteryHUD
    @Default(.showLowBatteryHUD) var showLowBatteryHUD
    @Default(.showFullBatteryHUD) var showFullBatteryHUD
    @Default(.showOnAllDisplays) var showOnAllDisplays
    @Default(.lowBatteryHUDStyle) var lowBatteryHUDStyle
    @Default(.fullBatteryHUDStyle) var fullBatteryHUDStyle
    
    // Dynamic sizing based on view type and graph count with smooth transitions
    var dynamicNotchSize: CGSize {
        let baseSize = Defaults[.enableMinimalisticUI] ? minimalisticOpenNotchSize(isDynamicIslandMode: isDynamicIslandMode) : openNotchSize
        
        // When inline sneak peek is active in closed notch, use the wider inline width
        // so the outer maxWidth frame doesn't clip the expanded content
        let airPodsListeningModeSneakActive = vm.notchState == .closed
            && coordinator.sneakPeek.show
            && coordinator.sneakPeek.type == .bluetoothAudio
            && coordinator.sneakPeek.value < 0
            && AirPodsListeningMode.fromHUDSymbol(coordinator.sneakPeek.icon) != nil
        let inlineSneakPeekActive = vm.notchState == .closed
            && (
                coordinator.expandingView.show
                    && (coordinator.expandingView.type == .music || coordinator.expandingView.type == .timer)
                    && Defaults[.sneakPeekStyles] == .inline
                || airPodsListeningModeSneakActive
            )
            && Defaults[.enableSneakPeek]
        if inlineSneakPeekActive {
            let inlineWidth: CGFloat = airPodsListeningModeSneakActive
                ? InlineHUD.airPodsListeningModeWidth(
                    closedNotchWidth: vm.closedNotchSize.width,
                    gestureProgress: gestureProgress,
                    minimalistic: Defaults[.enableMinimalisticUI]
                ) + notchHorizontalPadding * 2
                : 460
            return CGSize(width: max(baseSize.width, inlineWidth), height: baseSize.height)
        }
        
        // Handle battery HUD expansion sizing
        if vm.notchState == .closed && 
           coordinator.expandingView.show && 
           coordinator.expandingView.type == .battery &&
           isBatteryHUDVisibleOnCurrentScreen {
            
            if let kind = batteryModel.activeTemporaryHUDKind {
                let style: BatteryNotificationStyle = {
                    switch kind {
                    case .charging: return .compact
                    case .lowBattery: return Defaults[.lowBatteryHUDStyle]
                    case .fullBattery: return Defaults[.fullBatteryHUDStyle]
                    }
                }()
                
                var width = vm.closedNotchSize.width
                var height = vm.effectiveClosedNotchHeight
                
                switch (kind, style) {
                case (.charging, _), (.lowBattery, .compact), (.fullBattery, .compact):
                    width += 180
                case (.lowBattery, .standard):
                    width += 100
                    height += 75
                case (.fullBattery, .standard):
                    width += 80
                    height += 70
                }
                
                return CGSize(width: width, height: height)
            }
        }
        
        if coordinator.currentView == .timer {
            return CGSize(width: baseSize.width, height: 250) // Extra height for timer presets
        }
        
        if coordinator.currentView == .notes || coordinator.currentView == .clipboard {
            let preferredHeight = coordinator.notesLayoutState.preferredHeight
            let resolvedHeight = max(baseSize.height, preferredHeight)
            return CGSize(width: baseSize.width, height: resolvedHeight)
        }

        if coordinator.currentView == .terminal {
            // Dynamic height: up to terminalMaxHeightFraction of screen, min 300pt
            let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
            let maxFraction = Defaults[.terminalMaxHeightFraction]
            let terminalHeight = min(screenHeight * maxFraction, max(300, screenHeight * maxFraction))
            return CGSize(width: baseSize.width, height: terminalHeight)
        }

        return baseSize
    }
    

    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var lastHapticTime: Date = Date()
    @State private var hoverClickMonitor: Any?
    @State private var hoverClickLocalMonitor: Any?
    @State private var stickyTerminalClickMonitor: Any?
    @State private var hiddenEdgeHoverPollingTask: Task<Void, Never>?
    @State private var isHoveringClosedMusicWaveformControl: Bool = false

    @State private var gestureProgress: CGFloat = .zero
    /// Owns the floating music-control window's scheduling and visibility.
    /// One per ContentView, matching the @State it replaces — see the type's
    /// note on why this is not shared.
    @State private var musicControlWindow = MusicControlWindowController()
    @State private var skipGestureActiveDirection: MusicManager.SkipDirection?

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer
    @Default(.musicControlWindowEnabled) var musicControlWindowEnabled
    @Default(.showNotHumanFace) var showNotHumanFace
    @Default(.useModernCloseAnimation) var useModernCloseAnimation
    @Default(.enableMinimalisticUI) var enableMinimalisticUI



    private func runAfter(_ delay: TimeInterval, _ action: @escaping @Sendable @MainActor () -> Void) {
        guard delay >= 0 else { return }
        Task { @MainActor in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            action()
        }
    }

    private var dynamicNotchResizeAnimation: Animation? {
        nil
    }
    
    private let zeroHeightHoverPadding: CGFloat = 10

    // MARK: - Tab switch direction for smooth transitions
    
    private var tabSwitchTransition: AnyTransition {
        if coordinator.tabSwitchForward {
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        } else {
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }
    
    private var standardMediaControlsActive: Bool {
        showStandardMediaControls && !enableMinimalisticUI
    }

    private var closedMusicContentEnabled: Bool {
        enableMinimalisticUI || showStandardMediaControls
    }

    private var isMusicHUDDeferredAfterUnlock: Bool {
        lockScreenManager.shouldDelayPostUnlockMusicHUD
    }

    private var interactionsEnabled: Bool {
        !lockScreenManager.isLocked
    }

    private var isIslandMode: Bool {
        isDynamicIslandMode
    }

    private var notchHorizontalPadding: CGFloat {
        guard vm.notchState == .open else {
            return activeCornerRadiusInsets.closed.bottom
        }
        if Defaults[.cornerRadiusScaling] {
            return activeCornerRadiusInsets.opened.top - 5
        }
        return activeCornerRadiusInsets.opened.bottom - 5
    }

    private var bodyHoverAreaPadding: CGFloat {
        if vm.notchState == .open && Defaults[.extendHoverArea] {
            return 0
        }
        return vm.effectiveClosedNotchHeight == 0 ? zeroHeightHoverPadding : 0
    }

    private var notchBottomPadding: CGFloat {
        currentShadowPadding + bodyHoverAreaPadding
    }

    /// Extra hit area below the closed notch, when the user has asked for it.
    ///
    /// The closed notch's hover target is its own outline — `.contentShape` is
    /// given `resolvedClipShape`. With nothing playing that outline shrinks to
    /// the bare physical notch, and `minimumHoverDuration` requires holding the
    /// cursor inside it for the whole dwell, so a small drift cancels the open.
    ///
    /// This is applied *before* `.contentShape` and subtracted from the padding
    /// applied after it, so the hit area grows while the layout does not move.
    private var closedHoverExtension: CGFloat {
        guard Defaults[.extendHoverArea], vm.notchState == .closed else { return 0 }
        return 12
    }

    private var pillTopOffset: CGFloat {
        isIslandMode ? dynamicIslandTopOffset : 0
    }

    private func closedMusicPairingEligible(hasActiveMusicSnapshot: Bool) -> Bool {
        vm.notchState == .closed
            && hasActiveMusicSnapshot
            && coordinator.musicLiveActivityEnabled
            && closedMusicContentEnabled
            && !vm.hideOnClosed
            && !lockScreenManager.isLocked
            && !isMusicHUDDeferredAfterUnlock
    }

    private var closedLiveActivitySwapTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.965, anchor: .center))
                .animation(.spring(response: 0.34, dampingFraction: 0.88)),
            removal: .opacity
                .combined(with: .scale(scale: 0.92, anchor: .center))
                .animation(.smooth(duration: 0.22))
        )
    }
    
    // Use minimalistic corner radius ONLY when opened, keep normal when closed
    private var activeCornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) {
        if enableMinimalisticUI {
            // Keep normal closed corner radius, use minimalistic when opened
            return (opened: minimalisticCornerRadiusInsets.opened, closed: cornerRadiusInsets.closed)
        }
        return cornerRadiusInsets
    }
    
    private var currentShadowPadding: CGFloat {
        notchShadowPaddingValue(isMinimalistic: enableMinimalisticUI)
    }

    private var currentNotchShape: NotchShape {
        let topRadius = (vm.notchState == .open && Defaults[.cornerRadiusScaling])
            ? activeCornerRadiusInsets.opened.top
            : activeCornerRadiusInsets.closed.top
        let bottomRadius = (vm.notchState == .open && Defaults[.cornerRadiusScaling])
            ? activeCornerRadiusInsets.opened.bottom
            : activeCornerRadiusInsets.closed.bottom
        return NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
    }

    /// Whether the current screen should render as a Dynamic Island pill
    /// rather than the standard notch shape. Always false on physical notch screens.
    private var isDynamicIslandMode: Bool {
        shouldUseDynamicIslandMode(for: currentScreenName)
    }

    private var currentScreenName: String {
        vm.screen ?? coordinator.selectedScreen
    }

    /// Whether the current screen lacks a physical notch.
    private var isNonNotchScreen: Bool {
        guard let screen = NSScreen.screens.first(where: { $0.localizedName == currentScreenName }) else {
            return true
        }
        return screen.safeAreaInsets.top <= 0
    }

    /// Whether the global sneak peek is visible on this specific screen.
    private var isSneakPeekVisibleOnCurrentScreen: Bool {
        guard coordinator.sneakPeek.show else { return false }
        guard Defaults[.showOnAllDisplays] else { return true }
        guard let targetScreenName = coordinator.sneakPeek.targetScreenName else { return true }
        return currentScreenName == targetScreenName
    }

    /// Whether the notch/island should hide off-screen when closed on a non-notch display.
    /// Temporarily reveals the notch when a sneakPeek HUD (volume, brightness, music, etc.) is active.
    private var shouldHideUntilHover: Bool {
        hideNonNotchUntilHover && isNonNotchScreen && vm.notchState == .closed && !isSneakPeekVisibleOnCurrentScreen
    }

    /// Whether the fallback top-edge hover detector should run.
    /// This is only needed when the notch is fully hidden off-screen and
    /// regular `.onHover` hit-testing may not trigger reliably.
    private var shouldUseHiddenEdgeHoverPolling: Bool {
        shouldHideUntilHover && !lockScreenManager.isLocked
    }
    
    /// Pill shape for Dynamic Island mode with animated corner radius transitions.
    private var currentPillShape: AnchorPillShape {
        let radius: CGFloat
        if vm.notchState == .open {
            radius = enableMinimalisticUI
                ? minimalisticCornerRadiusInsets.opened.top
                : dynamicIslandPillCornerRadiusInsets.opened
        } else {
            // Use half the closed height for a true capsule shape
            radius = max(vm.closedNotchSize.height / 2, dynamicIslandPillCornerRadiusInsets.closed.standard)
        }
        return AnchorPillShape(cornerRadius: radius)
    }

    private var isBatteryHUDVisibleOnCurrentScreen: Bool {
        guard coordinator.expandingView.show, coordinator.expandingView.type == .battery else { return false }
        guard showPowerStatusNotifications else { return false }
        guard batteryModel.activeTemporaryHUDKind != nil else { return false }
        if showOnAllDisplays { return true }
        guard let targetScreenName = batteryModel.activeTemporaryHUDTargetScreenName else { return true }
        return currentScreenName == targetScreenName
    }

    private var isCurrentScreenExpansionVisible: Bool {
        guard coordinator.expandingView.show else { return false }
        if coordinator.expandingView.type == .battery {
            return isBatteryHUDVisibleOnCurrentScreen
        }
        return true
    }

    private var currentScreenExpansionType: SneakContentType? {
        isCurrentScreenExpansionVisible ? coordinator.expandingView.type : nil
    }

    private var displayedBatteryHUDLevel: Int {
        let resolvedLevel = batteryModel.activeTemporaryHUDLevelOverride
            ?? Int(batteryModel.levelBattery.rounded())
        return min(max(resolvedLevel, 0), 100)
    }

    private var displayedBatteryHUDUsesLowPowerMode: Bool {
        batteryModel.activeTemporaryHUDLowPowerModeOverride ?? batteryModel.isInLowPowerMode
    }


    private var activeClosedBatterySurfaceShape: AnyShape? {
        guard vm.notchState == .closed else { return nil }
        guard isBatteryHUDVisibleOnCurrentScreen else { return nil }
        guard let kind = batteryModel.activeTemporaryHUDKind else { return nil }

        if isDynamicIslandMode {
            let radius = dynamicIslandPillCornerRadiusInsets.opened
            return AnyShape(AnchorPillShape(cornerRadius: radius))
        } else {
            let topRadius = activeCornerRadiusInsets.closed.top
            let bottomRadius: CGFloat = {
                switch resolvedBatteryNotificationStyle(for: kind) {
                case .compact:
                    return activeCornerRadiusInsets.closed.bottom
                case .standard:
                    return kind == .fullBattery ? 36 : 40
                }
            }()
            return AnyShape(NotchShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius))
        }
    }

    private func resolvedBatteryNotificationStyle(for kind: BatteryTemporaryHUDKind) -> BatteryNotificationStyle {
        switch kind {
        case .charging:
            return .compact
        case .lowBattery:
            return lowBatteryHUDStyle
        case .fullBattery:
            return fullBatteryHUDStyle
        }
    }


    /// Resolves the clip/content shape per-screen: pill on non-notch screens
    /// when dynamic island mode is active, standard notch shape otherwise.
    private var resolvedClipShape: AnyShape {
        if let activeClosedBatterySurfaceShape {
            return activeClosedBatterySurfaceShape
        }
        if isDynamicIslandMode {
            return AnyShape(currentPillShape)
        }
        return AnyShape(currentNotchShape)
    }

    var body: some View {
        installRootLifecycleHandlers(on: rootBodyView)
    }

    private var mainLayoutBase: some View {
        NotchLayout()
            .frame(alignment: .top)
            .padding(.horizontal, notchHorizontalPadding)
            .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
            .background(.black)
            .clipShape(resolvedClipShape)
            .compositingGroup()
            .shadow(
                color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                    ? .black.opacity(0.6)
                    : .clear,
                radius: Defaults[.cornerRadiusScaling] ? 10 : 5
            )
            // Extra horizontal inset for Dynamic Island mode so the shadow
            // is not clipped by the outer frame constraint
            .padding(.horizontal, isIslandMode ? dynamicIslandShadowInset : 0)
            .padding(.bottom, isIslandMode ? dynamicIslandShadowInset : 0)
            .padding(.top, pillTopOffset)
            .accessibilityIdentifier("AnchorNotch")
    }

    /// The animation the notch's open/close uses, whichever branch of
    /// `configuredMainLayout` is live.
    ///
    /// Hoisted out of those branches because `rootBodyView`'s outer frame has to
    /// animate with the same curve. That frame changes `maxWidth` by 24pt keyed
    /// on `vm.notchState`, but it wraps `configuredMainLayout`, so the
    /// `.animation(_:value:)` inside never reached it — the container snapped to
    /// its closed width in one frame while the notch was still animating shut.
    private var activeNotchStateAnimation: Animation {
        guard useModernCloseAnimation else {
            return .spring.speed(1.2)
        }
        return vm.notchState == .open
            ? .spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
            : .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    }

    private var configuredMainLayout: some View {
        mainLayoutBase
            .conditionalModifier(!useModernCloseAnimation) { view in
                let hoverAnimation = Animation.bouncy.speed(1.2)
                return view
                    .animation(hoverAnimation, value: isHovering)
                    .animation(activeNotchStateAnimation, value: vm.notchState)
                    .animation(.smooth, value: gestureProgress)
                    .transition(.blurReplace.animation(.interactiveSpring(dampingFraction: 1.2)))
            }
            .conditionalModifier(useModernCloseAnimation) { view in
                let hoverAnimation = Animation.bouncy.speed(1.2)
                return view
                    .animation(hoverAnimation, value: isHovering)
                    .animation(activeNotchStateAnimation, value: vm.notchState)
                    .animation(.smooth, value: gestureProgress)
            }
            .conditionalModifier(interactionsEnabled) { view in
                view
                    .padding(.bottom, closedHoverExtension)
                    // A rect, not the notch outline: the outline's curved
                    // corners cut hittable area out of the very box we just
                    // grew. Only when extending — otherwise hover stays tight
                    // to the visible shape.
                    .contentShape(
                        closedHoverExtension > 0 ? AnyShape(Rectangle()) : resolvedClipShape)
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        if handleClosedMusicWaveformTapIfNeeded() {
                            return
                        }
                        if vm.notchState == .closed && Defaults[.enableHaptics] {
                            triggerHapticIfAllowed()
                        }
                        openNotch()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                            .panGesture(direction: .left) { translation, phase in
                                handleSkipGesture(direction: .forward, translation: translation, phase: phase)
                            }
                            .panGesture(direction: .right) { translation, phase in
                                handleSkipGesture(direction: .backward, translation: translation, phase: phase)
                            }
                    }
            }
            .conditionalModifier((Defaults[.closeGestureEnabled] || Defaults[.reverseScrollGestures]) && Defaults[.enableGestures] && interactionsEnabled) { view in
                view
                    .panGesture(direction: .up) { translation, phase in
                        handleUpGesture(translation: translation, phase: phase)
                    }
            }
            // Shadow bottom padding and hide-until-hover offset applied AFTER
            // interaction modifiers so .contentShape / .onHover only covers
            // the actual notch content, not the shadow clearance below it.
            .padding(.bottom, notchBottomPadding - closedHoverExtension)
            .offset(y: shouldHideUntilHover && !isHovering
                ? -(vm.closedNotchSize.height + pillTopOffset + currentShadowPadding + 10)
                : 0
            )
            .onAppear(perform: {
                if coordinator.firstLaunch {
                    // Single open during first launch; closeHello() handles the timed close.
                    runAfter(1) {
                        withAnimation(vm.animation) {
                            openNotch()
                        }
                    }
                }
            })
            .onChange(of: vm.notchState) { _, newState in
                // Reset hover state when notch state changes
                if newState == .closed && isHovering {
                    withAnimation {
                        isHovering = false
                    }
                }
                if newState != .closed {
                    isHoveringClosedMusicWaveformControl = false
                }
                if newState == .closed {
                    removeStickyTerminalClickMonitor()
                } else {
                    // Install the outside-click monitor for terminal opens that don't
                    // change `currentView` (e.g. shortcut re-opening with the terminal
                    // tab already selected, where the cursor never enters the notch).
                    syncStickyTerminalOutsideClickMonitor()
                }
                #if os(macOS)
                if newState == .open {
                    TimerControlWindowManager.shared.hide()
                }
                #endif
            }
            .onChange(of: vm.isBatteryPopoverActive) { _, newPopoverState in
                runAfter(0.1) {
                    if !newPopoverState && !isHovering && vm.notchState == .open && !shouldPreventAutoClose() {
                        vm.close()
                    }
                }
            }
            .onChange(of: vm.isStatsPopoverActive) { _, newPopoverState in
                runAfter(0.1) {
                    if !newPopoverState && !isHovering && vm.notchState == .open && !shouldPreventAutoClose() {
                        vm.close()
                    }
                }
            }
            .onChange(of: vm.shouldRecheckHover) { _, _ in
                // Recheck hover state when popovers are closed
                runAfter(0.1) {
                    if vm.notchState == .open && !shouldPreventAutoClose() && !isHovering {
                        vm.close()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                runAfter(0.1) {
                    if vm.notchState == .open && !isHovering && !shouldPreventAutoClose() {
                        vm.close()
                    }
                }
            }
            .onChange(of: coordinator.sneakPeek.show) { _, sneakPeekShowing in
                // When sneak peek finishes, check if user is still hovering and open notch if needed
                if !sneakPeekShowing {
                    runAfter(0.2) {
                        if isHovering && vm.notchState == .closed && !coordinator.isHoverOpenSuppressed {
                            openNotch()
                        }
                    }
                }
            }
            .onChange(of: coordinator.currentView) { _, newValue in
                syncStickyTerminalOutsideClickMonitor()
            }
            .sensoryFeedback(.alignment, trigger: haptics)
            .contextMenu {
                Button("Settings") {
                    SettingsWindowController.shared.showWindow()
                }
//                Button("Edit") { // Doesnt work....
//                    let dn = DynamicNotch(content: EditPanelView())
//                    dn.toggle()
//                }
//                #if DEBUG
//                .disabled(false)
//                #else
//                .disabled(true)
//                #endif
//                .keyboardShortcut("E", modifiers: .command)
            }
    }

    private var rootBodyView: some View {
        ZStack(alignment: .top) {
            configuredMainLayout
        }
        .frame(
            maxWidth: (dynamicNotchSize.width + (vm.notchState == .open ? 24 : 0) + (isDynamicIslandMode ? dynamicIslandShadowInset * 2 : 0)).rounded(),
            maxHeight: (dynamicNotchSize.height + (vm.notchState == .open ? 12 : 0) + (isDynamicIslandMode ? dynamicIslandTopOffset + dynamicIslandShadowInset * 2 : currentShadowPadding)).rounded(),
            alignment: .top
        )
        // Without this the 24pt maxWidth change above lands in a single frame
        // while the notch is still animating shut.
        .animation(activeNotchStateAnimation, value: vm.notchState)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environmentObject(privacyManager)
        .background(dragDetector)
        .environmentObject(vm)
    }

    private func installRootLifecycleHandlers<Content: View>(on view: Content) -> some View {
        installSecondaryRootLifecycleHandlers(
            on: installPrimaryRootLifecycleHandlers(on: view)
        )
    }

    private func installPrimaryRootLifecycleHandlers<Content: View>(on view: Content) -> some View {
        view
            .onAppear {
                musicControlWindow.configure(viewModel: vm)
                musicControlWindow.adoptCurrentState()
                syncMusicControlChrome()
                if musicManager.isPlaying || !musicManager.isPlayerIdle {
                    musicControlWindow.clearVisibilityDeadline()
                }
                musicControlWindow.clearVisibilityDeadlineIfExpired()
                musicControlWindow.enqueueSync(forceRefresh: true)
                syncHiddenEdgeHoverPolling()
                // Deterministic teardown for borderless panels (`.onDisappear` is
                // unreliable); the window-cleanup path calls this before closing.
                vm.onViewTeardown = { performViewTeardown() }
            }
            .onChange(of: terminalStickyMode) { _, _ in
                syncStickyTerminalOutsideClickMonitor()
            }
            .onChange(of: vm.notchState) { _, state in
                if state == .open {
                    musicControlWindow.suspend()
                } else {
                    musicControlWindow.resume()
                }
            }
            .onChange(of: musicControlWindowEnabled) { _, enabled in
                if enabled {
                    if musicManager.isPlaying || !musicManager.isPlayerIdle {
                        musicControlWindow.clearVisibilityDeadline()
                    }
                    musicControlWindow.enqueueSync(forceRefresh: true)
                } else {
                    musicControlWindow.disable()
                }
            }
            .onChange(of: coordinator.musicLiveActivityEnabled) { _, enabled in
                if enabled {
                    musicControlWindow.enqueueSync(forceRefresh: true)
                } else {
                    musicControlWindow.disable()
                }
            }
            .onChange(of: vm.hideOnClosed) { _, hidden in
                if hidden {
                    musicControlWindow.cancelSync()
                    musicControlWindow.hide()
                } else {
                    musicControlWindow.enqueueSync(forceRefresh: true, delay: 0.05)
                }
            }
            .onChange(of: lockScreenManager.isLocked) { _, locked in
                if locked {
                    musicControlWindow.suspend()
                } else {
                    musicControlWindow.resume()
                }
            }
            .onChange(of: lockScreenManager.shouldDelayPostUnlockMusicHUD) { _, deferred in
                if deferred {
                    musicControlWindow.suspend()
                } else {
                    musicControlWindow.resume(after: 0)
                }
            }
    }

    private func installSecondaryRootLifecycleHandlers<Content: View>(on view: Content) -> some View {
        view
            .onChange(of: showStandardMediaControls) { _, _ in
                musicControlWindow.handleStandardControlsAvailabilityChange()
            }
            .onChange(of: enableMinimalisticUI) { _, _ in
                musicControlWindow.handleStandardControlsAvailabilityChange()
            }
            .onChange(of: gestureProgress) { _, _ in
                syncMusicControlChrome()
                musicControlWindow.resyncGeometryIfShowing(delay: 0.05)
            }
            .onChange(of: isHovering) { _, hovering in
                syncMusicControlChrome()
                musicControlWindow.resyncGeometryIfShowing(delay: hovering ? 0.05 : 0.12)
            }
            .onChange(of: musicManager.isPlaying) { _, isPlaying in
                musicControlWindow.handlePlaybackChange(isPlaying: isPlaying)
            }
            .onChange(of: musicManager.isPlayerIdle) { _, isIdle in
                musicControlWindow.handleIdleChange(isIdle: isIdle)
            }
            .onChange(of: vm.closedNotchSize) { _, _ in
                syncMusicControlChrome()
                musicControlWindow.resyncGeometryIfShowing()
            }
            .onChange(of: vm.effectiveClosedNotchHeight) { _, _ in
                syncMusicControlChrome()
                musicControlWindow.resyncGeometryIfShowing()
            }
            .onDisappear {
                performViewTeardown()
            }
    }

    @ViewBuilder
      func NotchLayout() -> some View {
          VStack(alignment: .leading) {
              VStack(alignment: .leading) {
                  if coordinator.firstLaunch {
                      Spacer()
                      HelloAnimation().frame(width: 200, height: 80).onAppear(perform: {
                          vm.closeHello()
                      })
                      .padding(.top, 40)
                      Spacer()
                  } else {
                        let hasMusicMetadata = !musicManager.songTitle.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
                            || !musicManager.artistName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
                      let hasActiveMusicSnapshot: Bool = {
                          if musicManager.isPlaying { return true }
                          return !musicManager.isPlayerIdle && hasMusicMetadata
                      }()
                      let musicPairingEligible = closedMusicPairingEligible(hasActiveMusicSnapshot: hasActiveMusicSnapshot)
                      let musicSecondary = resolveMusicSecondaryLiveActivity(isMusicPairingEligible: musicPairingEligible)
                      let activeSneakPeekStyle = resolvedSneakPeekStyle()
                      let expansionMatchesSecondary: Bool = {
                          guard let musicSecondary else { return false }
                          switch musicSecondary {
                          case .timer:
                              return currentScreenExpansionType == .timer
                          case .reminder:
                              return currentScreenExpansionType == .reminder
                          case .recording:
                              return currentScreenExpansionType == .recording
                          case .focus:
                              return currentScreenExpansionType == .doNotDisturb
                          case .capsLock:
                              return false
                          }
                      }()
                      let canShowMusicDuringExpansion = !isCurrentScreenExpansionVisible
                          || currentScreenExpansionType == .music
                          || expansionMatchesSecondary
                      let isAirPodsListeningModeSneak = coordinator.sneakPeek.type == .bluetoothAudio
                          && coordinator.sneakPeek.value < 0
                          && AirPodsListeningMode.fromHUDSymbol(coordinator.sneakPeek.icon) != nil

                      if currentScreenExpansionType == .battery
                            && isBatteryHUDVisibleOnCurrentScreen
                            && vm.notchState == .closed
                            && Defaults[.showPowerStatusNotifications]
                            && batteryModel.activeTemporaryHUDKind != nil {
                        BatteryTemporaryActivityView(
                            kind: batteryModel.activeTemporaryHUDKind ?? .charging,
                            batteryLevel: displayedBatteryHUDLevel,
                            isLowPowerMode: displayedBatteryHUDUsesLowPowerMode,
                            closedNotchWidth: vm.closedNotchSize.width + (isHovering ? 8 : 0),
                            baseHeight: vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0),
                            isDynamicIslandMode: isDynamicIslandMode,
                            topCornerRadius: activeCornerRadiusInsets.closed.top,
                            styleOverride: batteryModel.activeTemporaryHUDKind.map { resolvedBatteryNotificationStyle(for: $0) }
                        )
                        .id(batteryModel.activeTemporaryHUDToken)
                      } else if isSneakPeekVisibleOnCurrentScreen && (Defaults[.inlineHUD] || isAirPodsListeningModeSneak) && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && (coordinator.sneakPeek.type != .timer) && (coordinator.sneakPeek.type != .reminder) && (coordinator.sneakPeek.type != .claudeUsage) && ((coordinator.sneakPeek.type != .volume && coordinator.sneakPeek.type != .brightness && coordinator.sneakPeek.type != .backlight) || vm.notchState == .closed) {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(
                                  coordinator.sneakPeek.type == .capsLock
                                      ? AnyTransition.move(edge: .trailing).combined(with: .opacity)
                                      : AnyTransition.opacity
                              )
                      } else if vm.notchState == .closed && dictationManager.state.isActive && showDictationLiveActivity && !vm.hideOnClosed {
                          DictationLiveActivity()
                              .id("dictation-live-activity")
                              .transition(closedLiveActivitySwapTransition)
                      } else if vm.notchState == .closed && capsLockManager.isCapsLockActive && Defaults[.enableCapsLockIndicator] && !vm.hideOnClosed && !lockScreenManager.isLocked {
                          InlineHUD(type: .constant(.capsLock), value: .constant(1.0), icon: .constant(""), hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(AnyTransition.move(edge: .trailing).combined(with: .opacity))
                      } else if canShowMusicDuringExpansion && musicPairingEligible {
                          MusicLiveActivity(secondary: musicSecondary)
                              .id("closed-music-live-activity")
                              .transition(closedLiveActivitySwapTransition)
                      // Below music on purpose. Every other activity above this
                      // point is short-lived — a held key, a caps-lock press —
                      // whereas a usage window runs for hours, and outranking
                      // music would silently take the closed notch away from the
                      // most-used surface for the whole of it.
                      // Above the usage countdown: a break prompt is twenty
                      // seconds long and the thing it is asking for is to stop
                      // looking at this screen, so it should not queue behind
                      // something that sits there for hours.
                      } else if vm.notchState == .closed && eyeBreakManager.isResting && !vm.hideOnClosed {
                          EyeBreakLiveActivity()
                              .id("eye-break-live-activity")
                              .transition(closedLiveActivitySwapTransition)
                      } else if vm.notchState == .closed && claudeUsageManager.isLiveActivityVisible && !vm.hideOnClosed {
                          ClaudeUsageLiveActivity()
                              .id("claude-usage-live-activity")
                              .transition(closedLiveActivitySwapTransition)
                      } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .timer) && vm.notchState == .closed && timerManager.isTimerActive && coordinator.timerLiveActivityEnabled && !vm.hideOnClosed {
                          TimerLiveActivity()
                      } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .reminder) && vm.notchState == .closed && reminderManager.isActive && enableReminderLiveActivity && !vm.hideOnClosed {
                          ReminderLiveActivity()
                      } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .recording) && vm.notchState == .closed && (recordingManager.isRecording || !recordingManager.isRecorderIdle) && Defaults[.enableScreenRecordingDetection] && !vm.hideOnClosed && !musicPairingEligible {
                          RecordingLiveActivity()
                      } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .download) && vm.notchState == .closed && downloadManager.isDownloading && Defaults[.enableDownloadListener] && !vm.hideOnClosed {
                          DownloadLiveActivity()
                              .transition(.blurReplace.animation(.interactiveSpring(dampingFraction: 1.2)))
                      } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .doNotDisturb) && vm.notchState == .closed && Defaults[.enableDoNotDisturbDetection] && Defaults[.showDoNotDisturbIndicator] && (doNotDisturbManager.isDoNotDisturbActive || doNotDisturbManager.isFocusToastDismissing) && !vm.hideOnClosed && !lockScreenManager.isLocked {
                          DoNotDisturbLiveActivity()
                    } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .lockScreen) && vm.notchState == .closed && (lockScreenManager.isLocked || !lockScreenManager.isLockIdle) && Defaults[.enableLockScreenLiveActivity] && !vm.hideOnClosed {
                        LockScreenLiveActivity()
                            .id("lock-screen-live-activity")
                            .transition(closedLiveActivitySwapTransition)
                    } else if (!isCurrentScreenExpansionVisible || currentScreenExpansionType == .privacy) && vm.notchState == .closed && privacyManager.hasAnyIndicator && (Defaults[.enableCameraDetection] || Defaults[.enableMicrophoneDetection]) && !vm.hideOnClosed {
                        PrivacyLiveActivity()
                      } else if false {
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                      } else if !isCurrentScreenExpansionVisible && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          AnchorFaceAnimation().animation(.interactiveSpring, value: musicManager.isPlayerIdle)
                      } else if vm.notchState == .open {
                          AnchorHeader()
                              .frame(height: (Defaults[.enableMinimalisticUI] && isDynamicIslandMode) ? nil : max(24, vm.effectiveClosedNotchHeight))
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }
                      
                      if isSneakPeekVisibleOnCurrentScreen {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && (coordinator.sneakPeek.type != .timer) && (coordinator.sneakPeek.type != .reminder) && (coordinator.sneakPeek.type != .capsLock) && (coordinator.sneakPeek.type != .claudeUsage) && !Defaults[.inlineHUD] && !isAirPodsListeningModeSneak && ((coordinator.sneakPeek.type != .volume && coordinator.sneakPeek.type != .brightness && coordinator.sneakPeek.type != .backlight) || vm.notchState == .closed) {
                              SystemEventIndicatorModifier(eventType: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, sendEventBack: { _ in
                                  //
                              })
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && activeSneakPeekStyle == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName), textColor: .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                          // Timer sneak peek
                          else if coordinator.sneakPeek.type == .timer {
                              if !vm.hideOnClosed && activeSneakPeekStyle == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "timer")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(timerManager.timerName + " - " + timerManager.formattedRemainingTime()), textColor: timerManager.timerColor, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(timerManager.timerColor)
                                  .padding(.bottom, 10)
                              }
                          }
                          else if coordinator.sneakPeek.type == .reminder {
                              if !vm.hideOnClosed && activeSneakPeekStyle == .standard, let reminder = reminderManager.activeReminder {
                                  GeometryReader { geo in
                                      let chipColor = Color(nsColor: reminder.event.calendar.color).ensureMinimumBrightness(factor: 0.7)
                                      HStack(spacing: 6) {
                                          RoundedRectangle(cornerRadius: 2)
                                              .fill(chipColor)
                                              .frame(width: 8, height: 12)
                                          MarqueeText(
                                              .constant(reminderSneakPeekText(for: reminder, now: reminderManager.currentDate)),
                                              textColor: reminderColor(for: reminder, now: reminderManager.currentDate),
                                              minDuration: 1,
                                              frameWidth: max(0, geo.size.width - 14)
                                          )
                                      }
                                  }
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier(shouldFixSizeForSneakPeek()) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
              
              ZStack {
                  if vm.notchState == .open {
                      Group {
                          switch coordinator.currentView {
                              case .home:
                                  NotchHomeView(albumArtNamespace: albumArtNamespace)
                              case .timer:
                                  NotchTimerView()
                            case .notes:
                                NotchNotesView()
                            case .clipboard:
                                NotchClipboardList()
                            case .terminal:
                                NotchTerminalView()
                            case .lyrics:
                                NotchLyricsView()
                            case .shelf:
                                NotchShelfView()
                            case .stats:
                                NotchStatsView()
                          }
                      }
                      .id(coordinator.currentView)
                      .transition(tabSwitchTransition)
                  }
              }
              .zIndex(1)
              .allowsHitTesting(vm.notchState == .open)
              .blur(radius: abs(gestureProgress) > 0.3 ? min(abs(gestureProgress), 8) : 0)
              .opacity(abs(gestureProgress) > 0.3 ? min(abs(gestureProgress * 2), 0.8) : 1)
              .animation(.smooth(duration: 0.3), value: coordinator.currentView)
          }
      }

    private func reminderColor(for reminder: ReminderLiveActivityManager.ReminderEntry, now: Date) -> Color {
        if isReminderCritical(reminder, now: now) {
            return .red
        }
        return Color(nsColor: reminder.event.calendar.color).ensureMinimumBrightness(factor: 0.7)
    }

    private func reminderSneakPeekText(for entry: ReminderLiveActivityManager.ReminderEntry, now: Date) -> String {
        let title = entry.event.title.isEmpty ? "Upcoming Reminder" : entry.event.title
        let remaining = max(entry.event.start.timeIntervalSince(now), 0)
        let window = TimeInterval(Defaults[.reminderSneakPeekDuration])

        if window > 0 && remaining <= window {
            return "\(title) • \(String(format: String(localized: "now")))"
        }

        let minutes = Int(ceil(remaining / 60))
        let timeString = reminderTimeFormatter.string(from: entry.event.start)

        if minutes <= 0 {
            return "\(title) • \(String(format: String(localized: "now"))) • \(timeString)"
        } else if minutes == 1 {
            return "\(title) • \(String(format: String(localized: "in %@"), String(localized: "1 min"))) • \(timeString)"
        } else {
            return "\(title) • \(String(format: String(localized: "in %lld"), (minutes))) \(String(format: String(localized: "min plural"))) • \(timeString)"
        }
    }


    private let reminderTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    @ViewBuilder
    func AnchorFaceAnimation() -> some View {
        let sideSize = max(0, vm.effectiveClosedNotchHeight - 12)
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(width: sideSize, height: sideSize)
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                IdleAnimationView()
                    .frame(width: sideSize, height: sideSize)
            }
        }.frame(height: vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0), alignment: .center)
    }

    @ViewBuilder
    private func MusicLiveActivity(secondary preResolvedSecondary: MusicSecondaryLiveActivity? = nil) -> some View {
        let secondary = preResolvedSecondary ?? resolveMusicSecondaryLiveActivity()
        let notchContentHeight = max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12))
        let wingBaseWidth = max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12) + gestureProgress / 2)
        let rawCenterBaseWidth = vm.closedNotchSize.width + (isHovering ? 8 : 0)
        let centerBaseWidth = max(rawCenterBaseWidth, 96)
        let inlineSneakPeekActive = (
            coordinator.expandingView.show &&
            (coordinator.expandingView.type == .music || coordinator.expandingView.type == .timer) &&
            Defaults[.enableSneakPeek] &&
            Defaults[.sneakPeekStyles] == .inline
        )
        let rightWingWidth = resolvedRightWingWidth(
            for: secondary,
            baseWidth: wingBaseWidth,
            centerBaseWidth: centerBaseWidth,
            notchHeight: notchContentHeight
        )
        let effectiveCenterWidth = inlineSneakPeekActive ? 380 : centerBaseWidth
        let notchWidth = wingBaseWidth + effectiveCenterWidth + rightWingWidth
        let badgeBaseSize = max(13, notchContentHeight * 0.36)
        let badgeDisplaySize = badgeDisplaySize(for: secondary, baseSize: badgeBaseSize)
        let badgeOffset = badgeOverlayOffset(for: secondary, badgeSize: badgeDisplaySize)

        HStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .background(
                        Image(nsImage: musicManager.albumArt)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: musicManager.albumArt.size.width/musicManager.albumArt.size.height > 1.0 ? MusicPlayerImageSizes.cornerRadiusInset.closed/3.0 : MusicPlayerImageSizes.cornerRadiusInset.closed))
                    )
                    .clipped()
                    .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                    .albumArtFlip(angle: musicManager.flipAngle)
                albumArtBadge(for: secondary, badgeSize: badgeDisplaySize)
                    .offset(x: badgeOffset.width, y: badgeOffset.height)
                    .id(secondary?.id ?? "music-badge")
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: wingBaseWidth, height: notchContentHeight)

            Rectangle()
                .fill(.black)
                .frame(width: effectiveCenterWidth, height: notchContentHeight)
                .overlay(
                    HStack(alignment: .top) {
                        if(coordinator.expandingView.show && coordinator.expandingView.type == .music) {
                            MusicTitleMarqueeView(
                                text: musicManager.songTitle,
                                isExplicit: musicManager.isCurrentTrackExplicit,
                                textColor: Defaults[.coloredSpectrogram] ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: max(0, (effectiveCenterWidth - vm.closedNotchSize.width) / 2 - 12),
                                badgeHeight: 13
                            )
                            .padding(.leading, 8)
                            .opacity((coordinator.expandingView.show && Defaults[.enableSneakPeek] && Defaults[.sneakPeekStyles] == .inline) ? 1 : 0)
                            Spacer(minLength: vm.closedNotchSize.width)
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(Defaults[.coloredSpectrogram] ? Color(nsColor: musicManager.avgColor) : Color.gray)
                                .padding(.trailing, 8)
                                .opacity((coordinator.expandingView.show && coordinator.expandingView.type == .music && Defaults[.enableSneakPeek] && Defaults[.sneakPeekStyles] == .inline) ? 1 : 0)
                        } else if(coordinator.expandingView.show && coordinator.expandingView.type == .timer) {
                            MarqueeText(
                                .constant(timerManager.timerName),
                                textColor: timerManager.timerColor,
                                minDuration: 0.4,
                                frameWidth: max(0, (effectiveCenterWidth - vm.closedNotchSize.width) / 2 - 12)
                            )
                            .padding(.leading, 8)
                            .opacity((coordinator.expandingView.show && Defaults[.enableSneakPeek] && Defaults[.sneakPeekStyles] == .inline) ? 1 : 0)
                            Spacer(minLength: vm.closedNotchSize.width)
                            Text(timerManager.formattedRemainingTime())
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(timerManager.timerColor)
                                .padding(.trailing, 8)
                                .opacity((coordinator.expandingView.show && coordinator.expandingView.type == .timer && Defaults[.enableSneakPeek] && Defaults[.sneakPeekStyles] == .inline) ? 1 : 0)
                        } else if Defaults[.showSongMetadataInClosedNotch] && isNonNotchScreen && !musicManager.songTitle.isEmpty {
                            MarqueeText(
                                .constant("\(musicManager.songTitle) • \(musicManager.artistName)"),
                                textColor: Defaults[.coloredSpectrogram] ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 3,
                                frameWidth: max(0, effectiveCenterWidth - 16)
                            )
                            .padding(.horizontal, 8)
                        }
                    }
                    .clipped()
                )

            musicRightWing(for: secondary, notchHeight: notchContentHeight, trailingWidth: rightWingWidth)
                .frame(width: rightWingWidth, height: notchContentHeight, alignment: .center)
                .contentShape(Rectangle())
                .onHover { hovering in
                    guard shouldShowClosedMusicWaveformPlayPauseOverlay(for: secondary) else {
                        if isHoveringClosedMusicWaveformControl {
                            isHoveringClosedMusicWaveformControl = false
                        }
                        return
                    }
                    withAnimation(.smooth(duration: 0.16)) {
                        isHoveringClosedMusicWaveformControl = hovering
                    }
                }
                .id(secondary?.id ?? "music-spectrum")
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: notchWidth, height: notchContentHeight)
        .frame(height: vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0), alignment: .center)
        .animation(.smooth(duration: 0.25), value: secondary?.id)
    }

    private func resolveMusicSecondaryLiveActivity(isMusicPairingEligible: Bool = true) -> MusicSecondaryLiveActivity? {
        if coordinator.timerLiveActivityEnabled && timerManager.isTimerActive {
            return .timer
        }

        if enableReminderLiveActivity, reminderManager.isActive, let reminder = reminderManager.activeReminder {
            return .reminder(reminder)
        }

        if enableScreenRecordingDetection && (recordingManager.isRecording || !recordingManager.isRecorderIdle) {
            return .recording
        }

        if enableDoNotDisturbDetection && showDoNotDisturbIndicator && doNotDisturbManager.isDoNotDisturbActive {
            let mode = FocusModeType.resolve(identifier: doNotDisturbManager.currentFocusModeIdentifier, name: doNotDisturbManager.currentFocusModeName)
            return .focus(mode)
        }

        if enableCapsLockIndicator && capsLockManager.isCapsLockActive {
            return .capsLock(showLabel: showCapsLockLabel)
        }

        return nil
    }

    private func resolvedRightWingWidth(for secondary: MusicSecondaryLiveActivity?, baseWidth: CGFloat, centerBaseWidth: CGFloat, notchHeight: CGFloat) -> CGFloat {
        guard let secondary else { return baseWidth }

        switch secondary {
        case .timer:
            return timerRightWingWidth(baseWidth: baseWidth, centerBaseWidth: centerBaseWidth)
        case .reminder(let entry):
            return reminderRightWingWidth(for: entry, baseWidth: baseWidth, notchHeight: notchHeight, now: reminderManager.currentDate)
        case .capsLock(let showLabel):
            return showLabel ? scaledWingWidth(baseWidth: baseWidth, centerBaseWidth: centerBaseWidth, factor: 0.4, extra: 12) : baseWidth
        case .focus:
            return focusRightWingWidth(baseWidth: baseWidth)
        case .recording:
            return recordingRightWingWidth(baseWidth: baseWidth)
        }
    }

    private func timerRightWingWidth(baseWidth: CGFloat, centerBaseWidth: CGFloat) -> CGFloat {
        if timerShowsCountdown {
            return timerCountdownWingWidth(baseWidth: baseWidth)
        }

        let showsProgress = timerShowsProgress
        let usesRingProgress = timerProgressStyle == .ring

        switch (showsProgress, usesRingProgress) {
        case (true, true):
            return scaledWingWidth(baseWidth: baseWidth, centerBaseWidth: centerBaseWidth, factor: 0.46, extra: 18)
        case (true, false):
            return scaledWingWidth(baseWidth: baseWidth, centerBaseWidth: centerBaseWidth, factor: 0.52, extra: 24)
        case (false, _):
            return scaledWingWidth(baseWidth: baseWidth, centerBaseWidth: centerBaseWidth, factor: 0.38, extra: 12)
        }
    }

    private func timerCountdownWingWidth(baseWidth: CGFloat) -> CGFloat {
        let padding: CGFloat = 18
        let ringWidth: CGFloat = (timerShowsProgress && timerProgressStyle == .ring) ? 30 : 0
        let spacing: CGFloat = (ringWidth > 0) ? 8 : 0
        let countdownText = timerManager.formattedRemainingTime()
        let countdownWidth = TimerSupplementMetrics.countdownFrameWidth(for: countdownText)
        return max(baseWidth, padding + ringWidth + spacing + countdownWidth)
    }

    private func reminderRightWingWidth(for entry: ReminderLiveActivityManager.ReminderEntry, baseWidth: CGFloat, notchHeight: CGFloat, now: Date) -> CGFloat {
        let padding: CGFloat = 16
        switch reminderPresentationStyle {
        case .ringCountdown:
            let diameter = ReminderSupplementMetrics.ringDiameter(for: notchHeight)
            return max(baseWidth, padding + diameter)
        case .digital:
            let countdownText = ReminderSupplementMetrics.digitalCountdownText(for: entry, now: now)
            let width = ReminderSupplementMetrics.digitalFrameWidth(for: countdownText)
            return max(baseWidth, padding + width)
        case .minutes:
            let minutesText = ReminderSupplementMetrics.minutesCountdownText(for: entry, now: now)
            let width = ReminderSupplementMetrics.minutesFrameWidth(for: minutesText)
            return max(baseWidth, padding + width)
        }
    }

    private func focusRightWingWidth(baseWidth: CGFloat) -> CGFloat {
        // Focus pairings now mirror the default music spectrum width to keep the notch compact.
        return baseWidth
    }

    private func recordingRightWingWidth(baseWidth: CGFloat) -> CGFloat {
        // Keep recording pairings compact by reducing the width relative to the notch height.
        let absoluteMin: CGFloat = 38
        let preferredWidth = max(baseWidth * 0.6, 0)
        let maxWidth = min(baseWidth - 6, 52)
        let clampedPreferred = min(preferredWidth, maxWidth)
        return min(baseWidth, max(absoluteMin, clampedPreferred))
    }

    private func scaledWingWidth(baseWidth: CGFloat, centerBaseWidth: CGFloat, factor: CGFloat, extra: CGFloat) -> CGFloat {
        max(baseWidth, max(centerBaseWidth * factor, baseWidth + extra))
    }

    @ViewBuilder
    private func albumArtBadge(for secondary: MusicSecondaryLiveActivity?, badgeSize: CGFloat) -> some View {
        if let secondary, badgeSize > 0 {
            ZStack {
                Circle()
                    .fill(Color.black)

                switch secondary {
                case .timer:
                    Image(systemName: "timer")
                        .font(.system(size: badgeSize * 0.55, weight: .semibold))
                        .foregroundStyle(timerAccentColor)
                case .reminder(let entry):
                    let accent = reminderColor(for: entry, now: reminderManager.currentDate)
                    Image(systemName: "clock")
                        .font(.system(size: badgeSize * 0.55, weight: .semibold))
                        .foregroundStyle(accent)
                case .focus(let mode):
                    mode.resolvedActiveIcon(usePrivateSymbol: true)
                        .renderingMode(.template)
                        .font(.system(size: badgeSize * 0.5, weight: .semibold))
                        .foregroundStyle(mode.accentColor)
                case .recording:
                    Circle()
                        .fill(Color.red)
                        .frame(width: badgeSize * 0.45, height: badgeSize * 0.45)
                        .modifier(PulsingModifier())
                case .capsLock:
                    Image(systemName: "capslock.fill")
                        .font(.system(size: badgeSize * 0.5, weight: .semibold))
                        .foregroundStyle(capsLockTintMode.color)
                }
            }
            .frame(width: badgeSize, height: badgeSize)
            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
            .transition(.opacity.combined(with: .scale))
        } else {
            EmptyView()
        }
    }

    private func badgeDisplaySize(for secondary: MusicSecondaryLiveActivity?, baseSize: CGFloat) -> CGFloat {
        guard let secondary else { return baseSize }
        switch secondary {
        default:
            return baseSize
        }
    }

    private func badgeOverlayOffset(for secondary: MusicSecondaryLiveActivity?, badgeSize: CGFloat) -> CGSize {
        guard let secondary else { return CGSize(width: badgeSize * 0.2, height: badgeSize * 0.25) }
        switch secondary {
        default:
            return CGSize(width: badgeSize * 0.2, height: badgeSize * 0.25)
        }
    }

    @ViewBuilder
    private func musicRightWing(for secondary: MusicSecondaryLiveActivity?, notchHeight: CGFloat, trailingWidth: CGFloat) -> some View {
        switch secondary {
        case .timer:
            MusicTimerSupplementView(
                timerManager: timerManager,
                accentColor: timerAccentColor,
                showsCountdown: timerShowsCountdown,
                showsProgress: timerShowsProgress,
                progressStyle: timerProgressStyle,
                notchHeight: notchHeight
            )
        case .reminder(let entry):
            MusicReminderSupplementView(
                entry: entry,
                now: reminderManager.currentDate,
                style: reminderPresentationStyle,
                accent: reminderColor(for: entry, now: reminderManager.currentDate),
                notchHeight: notchHeight
            )
        case .capsLock(let showLabel):
            if showLabel {
                MusicCapsLockLabelView(color: capsLockTintMode.color)
            } else {
                spectrumView(forceSpectrum: true)
            }
        case .focus:
            spectrumView(forceSpectrum: true)
        case .recording:
            spectrumView(forceSpectrum: true, trailingInset: 6)
        case .none:
            spectrumView(
                forceSpectrum: false,
                enableClosedPlayPauseOverlay: shouldShowClosedMusicWaveformPlayPauseOverlay(for: secondary)
            )
        }
    }

    @ViewBuilder
    private func SpectrumVisualizer(
        useMusicVisualizer: Bool,
        forceSpectrum: Bool
    ) -> some View {
        let width = CGFloat(Defaults[.visualizerBarCount]) * 4
        if useMusicVisualizer || forceSpectrum {
            Rectangle()
                .fill((Defaults[.coloredSpectrogram] ? Color(nsColor: musicManager.avgColor) : Color.gray).spectrogramGradient())
                .frame(width: 50, alignment: .center)
                .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                .mask {
                    AudioVisualizerView(isPlaying: $musicManager.isPlaying)
                        .frame(width: width, height: 12)
                }
        }
    }

    @ViewBuilder
    private func spectrumView(
        forceSpectrum: Bool,
        trailingInset: CGFloat = 0,
        enableClosedPlayPauseOverlay: Bool = false
    ) -> some View {
        if useMusicVisualizer || forceSpectrum {
            SpectrumVisualizer(useMusicVisualizer: useMusicVisualizer, forceSpectrum: forceSpectrum)
                .blur(radius: (enableClosedPlayPauseOverlay && isHoveringClosedMusicWaveformControl) ? 2.4 : 0)
                .overlay {
                    if enableClosedPlayPauseOverlay {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black.opacity(isHoveringClosedMusicWaveformControl ? 0.24 : 0.02))

                            Image(systemName: musicManager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(isHoveringClosedMusicWaveformControl ? 0.98 : 0.0))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, trailingInset)
                .animation(.smooth(duration: 0.16), value: isHoveringClosedMusicWaveformControl)
                .animation(.smooth(duration: 0.2), value: musicManager.isPlaying)
        } else {
            LottieAnimationView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var timerAccentColor: Color {
        switch timerIconColorMode {
        case .adaptive:
            if let presetId = timerManager.activePresetId,
               let preset = timerPresets.first(where: { $0.id == presetId }) {
                return preset.color
            }
            return timerManager.timerColor
        case .solid:
            return timerSolidColor
        }
    }

    private func reminderIconName(for reminder: ReminderLiveActivityManager.ReminderEntry, now: Date) -> String {
        isReminderCritical(reminder, now: now) ? ReminderLiveActivityManager.criticalIconName : ReminderLiveActivityManager.standardIconName
    }

    private func isReminderCritical(_ reminder: ReminderLiveActivityManager.ReminderEntry, now: Date) -> Bool {
        let window = TimeInterval(Defaults[.reminderSneakPeekDuration])
        guard window > 0 else { return false }
        let remaining = reminder.event.start.timeIntervalSince(now)
        return remaining > 0 && remaining <= window
    }





    @MainActor
    
    @ViewBuilder
    var dragDetector: some View {
        // The shelf this used to feed was removed; nothing consumes drops now.
        EmptyView()
    }

    // MARK: - Private Methods
    private func openNotch() {
        withAnimation(.bouncy.speed(1.2)) {
            vm.open()
        }
    }

    private func shouldShowClosedMusicWaveformPlayPauseOverlay(for secondary: MusicSecondaryLiveActivity?) -> Bool {
        guard secondary == nil else { return false }
        return isClosedMusicGestureContext && !Defaults[.openNotchOnHover]
    }

    private var isClosedMusicGestureContext: Bool {
        vm.notchState == .closed
            && coordinator.musicLiveActivityEnabled
            && closedMusicContentEnabled
            && !vm.hideOnClosed
            && !lockScreenManager.isLocked
            && !isMusicHUDDeferredAfterUnlock
            && !isCurrentScreenExpansionVisible
            && (!musicManager.isPlayerIdle || musicManager.bundleIdentifier != nil)
            && !coordinator.firstLaunch
    }

    private func handleClosedMusicWaveformTapIfNeeded() -> Bool {
        guard shouldShowClosedMusicWaveformPlayPauseOverlay(for: nil),
              isHoveringClosedMusicWaveformControl else {
            return false
        }

        if Defaults[.enableHaptics] {
            triggerHapticIfAllowed()
        }
        musicManager.playPause()
        return true
    }

    private func hiddenHoverActivationContainsMouse(_ location: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.localizedName == currentScreenName }) else {
            return false
        }

        let horizontalPadding: CGFloat = 8
        let activationWidth = vm.closedNotchSize.width + horizontalPadding * 2
        let activationHeight = max(vm.closedNotchSize.height + zeroHeightHoverPadding, 14)

        let activationRect = CGRect(
            x: screen.frame.midX - activationWidth / 2,
            y: screen.frame.maxY - activationHeight,
            width: activationWidth,
            height: activationHeight
        )

        return activationRect.contains(location)
    }

    /// Cancels every long-lived task / event monitor this view owns. Called from
    /// `.onDisappear` and from `vm.onViewTeardown` on window close. Idempotent.
    /// Hands the controller the three view-owned values the floating window's
    /// geometry depends on. Called wherever any of them can change.
    private func syncMusicControlChrome() {
        musicControlWindow.updateChrome(
            .init(
                isHovering: isHovering,
                gestureProgress: gestureProgress,
                closedBottomCornerRadius: activeCornerRadiusInsets.closed.bottom))
    }

    private func performViewTeardown() {
        hoverTask?.cancel()
        stopHoverClickMonitor()
        removeStickyTerminalClickMonitor()
        stopHiddenEdgeHoverPolling()
        musicControlWindow.teardown()
        isHoveringClosedMusicWaveformControl = false
    }

    /// Starts or stops the hidden-edge hover poll to match current settings.
    ///
    /// The poll only means anything in hide-until-hover mode, but it used to be
    /// started unconditionally and then no-op every tick — a 20Hz main-actor
    /// wakeup that did nothing for the default configuration. Drive it from the
    /// gate instead, and re-evaluate whenever the gate changes.
    private func syncHiddenEdgeHoverPolling() {
        if shouldUseHiddenEdgeHoverPolling {
            startHiddenEdgeHoverPolling()
        } else {
            stopHiddenEdgeHoverPolling()
        }
    }

    private func startHiddenEdgeHoverPolling() {
        guard hiddenEdgeHoverPollingTask == nil else { return }

        hiddenEdgeHoverPollingTask = Task { @MainActor in
            while !Task.isCancelled {
                guard self.shouldUseHiddenEdgeHoverPolling else { break }

                let hovering = self.hiddenHoverActivationContainsMouse()
                if hovering != self.isHovering {
                    self.handleHover(hovering)
                }

                try? await Task.sleep(for: .milliseconds(50))
            }

            self.hiddenEdgeHoverPollingTask = nil
        }
    }

    private func stopHiddenEdgeHoverPolling() {
        hiddenEdgeHoverPollingTask?.cancel()
        hiddenEdgeHoverPollingTask = nil
    }

    private func startHoverClickMonitor() {
        guard Defaults[.openNotchOnHover] else { return }
        guard hoverClickMonitor == nil else { return }

        let handleClick: @Sendable () -> Void = { [weak vm, weak lockScreenManager] in
            Task { @MainActor in
                guard let vm, let lockScreenManager else { return }
                guard !lockScreenManager.isLocked else { return }
                guard vm.notchState == .closed else { return }
                guard !self.coordinator.isHoverOpenSuppressed else { return }
                guard self.isHovering else { return }
                guard !self.handleClosedMusicWaveformTapIfNeeded() else { return }
                if Defaults[.enableHaptics] {
                    self.triggerHapticIfAllowed()
                }
                self.openNotch()
            }
        }

        // Global monitor catches clicks outside the app window (e.g. when
        // the cursor is at the very top screen edge and the click goes to
        // the system rather than our panel).
        hoverClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
            handleClick()
        }

        // Local monitor catches clicks that DO hit our window — at the
        // screen edge SwiftUI's .onTapGesture may not fire reliably, but
        // the NSEvent local monitor will.
        hoverClickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            handleClick()
            return event
        }
    }

    private func stopHoverClickMonitor() {
        if let hoverClickMonitor {
            NSEvent.removeMonitor(hoverClickMonitor)
            self.hoverClickMonitor = nil
        }
        if let hoverClickLocalMonitor {
            NSEvent.removeMonitor(hoverClickLocalMonitor)
            self.hoverClickLocalMonitor = nil
        }
    }

    /// Installs the global outside-click monitor whenever the Terminal tab is open
    /// (e.g. keyboard-opened terminal), regardless of sticky mode.
    ///
    /// Sticky mode only controls whether the terminal closes when the cursor leaves
    /// the notch (see `shouldPreventAutoClose`).  An outside click should always close
    /// the terminal — this covers the case where the terminal is opened via the
    /// shortcut and the cursor never enters the notch, so there's no hover-out event
    /// to trigger the normal auto-close.
    ///
    /// While the cursor is hovering inside the notch, hover handling owns close
    /// behavior, so the monitor is not installed; it is re-synced on hover-out.
    private func syncStickyTerminalOutsideClickMonitor() {
        guard vm.notchState == .open, coordinator.currentView == .terminal, !isHovering else {
            removeStickyTerminalClickMonitor()
            return
        }
        installStickyTerminalClickMonitor()
    }

    private func installStickyTerminalClickMonitor() {
        guard stickyTerminalClickMonitor == nil else { return }
        stickyTerminalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak vm] _ in
            Task { @MainActor in
                guard let vm, vm.notchState == .open else { return }
                let clickLocation = NSEvent.mouseLocation
                if self.isPointInsideNotchWindow(clickLocation) {
                    return
                }
                vm.close()
            }
        }
    }

    private func removeStickyTerminalClickMonitor() {
        if let stickyTerminalClickMonitor {
            NSEvent.removeMonitor(stickyTerminalClickMonitor)
            self.stickyTerminalClickMonitor = nil
        }
    }

    // MARK: - Hover Management
    
    /// Handle hover state changes with debouncing
    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()

        if hovering {
            startHoverClickMonitor()
            removeStickyTerminalClickMonitor()
        } else {
            stopHoverClickMonitor()
            if isHoveringClosedMusicWaveformControl {
                withAnimation(.smooth(duration: 0.16)) {
                    isHoveringClosedMusicWaveformControl = false
                }
            }
        }

        if hovering {
            withAnimation(.bouncy.speed(1.2)) {
                isHovering = true
            }

            if vm.notchState == .closed && Defaults[.enableHaptics] {
                triggerHapticIfAllowed()
            }

            let shouldFocusTimerTab = enableTimerFeature && timerDisplayMode == .tab && timerManager.isTimerActive && !enableMinimalisticUI

            guard vm.notchState == .closed,
                !isSneakPeekVisibleOnCurrentScreen,
                (Defaults[.openNotchOnHover] || shouldFocusTimerTab) else { return }

            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.isSneakPeekVisibleOnCurrentScreen,
                          !self.coordinator.isHoverOpenSuppressed else { return }

                    if shouldFocusTimerTab {
                        withAnimation(.smooth) {
                            self.coordinator.currentView = .timer
                        }
                    }
                    self.openNotch()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(.bouncy.speed(1.2)) {
                        self.isHovering = false
                    }

                    if self.vm.notchState == .open && !self.shouldPreventAutoClose() {
                        self.vm.close()
                    } else if self.vm.notchState == .open
                                && Defaults[.terminalStickyMode]
                                && self.coordinator.currentView == .terminal {
                        // Re-sync monitor state through one code path to avoid
                        // monitor lifecycle races between hover and state updates.
                        self.syncStickyTerminalOutsideClickMonitor()
                    }
                }
            }
        }
    }

    private func isPointInsideNotchWindow(_ point: CGPoint) -> Bool {
        if let appDelegate = AppDelegate.shared {
            if Defaults[.showOnAllDisplays] {
                return appDelegate.windows.values.contains(where: { $0.frame.contains(point) })
            }
            if let window = appDelegate.window {
                return window.frame.contains(point)
            }
        }

        return NSApp.windows.contains(where: { $0.frame.contains(point) })
    }
    
    // Helper function to check if any popovers are active
    private func hasAnyActivePopovers() -> Bool {
     return vm.isBatteryPopoverActive || 
         vm.isClipboardPopoverActive || 
         vm.isColorPickerPopoverActive || 
         vm.isStatsPopoverActive ||
         vm.isTimerPopoverActive ||
         vm.isMediaOutputPopoverActive ||
         vm.isReminderPopoverActive
    }

    private func shouldPreventAutoClose() -> Bool {
        coordinator.firstLaunch || hasAnyActivePopovers() || vm.isAutoCloseSuppressed || SharingStateManager.shared.preventNotchClose || (Defaults[.terminalStickyMode] && coordinator.currentView == .terminal)
    }
    
    // Helper to prevent rapid haptic feedback
    private func triggerHapticIfAllowed() {
        let now = Date()
        if now.timeIntervalSince(lastHapticTime) > 0.3 { // Minimum 300ms between haptics
            haptics.toggle()
            lastHapticTime = now
        }
    }
    


    // Estimate the height required for minimalistic overrides (notably web content) and clamp it to the notch bounds.
    
    // MARK: - Gesture Handling
    
    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        handleScrollGesture(isDownward: true, translation: translation, phase: phase)
    }
    
    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        handleScrollGesture(isDownward: false, translation: translation, phase: phase)
    }

    private func handleScrollGesture(isDownward: Bool, translation: CGFloat, phase: NSEvent.Phase) {
        let reverse = Defaults[.reverseScrollGestures]
        let shouldOpen = isDownward ? !reverse : reverse

        if shouldOpen {
            handleOpenScrollGesture(translation: translation, phase: phase)
        } else {
            guard Defaults[.closeGestureEnabled] else { return }
            handleCloseScrollGesture(translation: translation, phase: phase)
        }
    }

    private func handleOpenScrollGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        withAnimation(.smooth) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if phase == .ended {
            withAnimation(.smooth) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                triggerHapticIfAllowed()
            }
            withAnimation(.smooth) {
                gestureProgress = .zero
            }
            openNotch()
        }
    }

    private func handleCloseScrollGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open, !vm.isHoveringCalendar, !vm.isScrollGestureActive else { return }

        withAnimation(.smooth) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(.smooth) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(.smooth) {
                gestureProgress = .zero
                isHovering = false
            }
            vm.close()

            if Defaults[.enableHaptics] {
                triggerHapticIfAllowed()
            }
        }
    }

    private func handleSkipGesture(direction: MusicManager.SkipDirection, translation: CGFloat, phase: NSEvent.Phase) {
        if phase == .ended {
            skipGestureActiveDirection = nil
            return
        }

        guard canPerformSkipGesture() else {
            skipGestureActiveDirection = nil
            return
        }

        if skipGestureActiveDirection == nil && translation > Defaults[.gestureSensitivity] {
            let effectiveDirection: MusicManager.SkipDirection
            if Defaults[.reverseSwipeGestures] {
                effectiveDirection = direction == .forward ? .backward : .forward
            } else {
                effectiveDirection = direction
            }
            skipGestureActiveDirection = effectiveDirection

            if Defaults[.enableHaptics] {
                triggerHapticIfAllowed()
            }

            musicManager.handleSkipGesture(direction: effectiveDirection)
        }
    }

    private func canPerformSkipGesture() -> Bool {
        let canSkipInOpenHome = vm.notchState == .open && coordinator.currentView == .home
        let canSkipInClosedMusic = !Defaults[.openNotchOnHover] && isClosedMusicGestureContext

        return enableHorizontalMusicGestures
            && (canSkipInOpenHome || canSkipInClosedMusic)
            && (!musicManager.isPlayerIdle || musicManager.bundleIdentifier != nil)
            && !lockScreenManager.isLocked
            && !hasAnyActivePopovers()
            && !vm.isHoveringCalendar
            && !vm.isScrollGestureActive
    }

















    
    private func shouldFixSizeForSneakPeek() -> Bool {
        guard isSneakPeekVisibleOnCurrentScreen else { return false }
        let style = resolvedSneakPeekStyle()
        
        // Original logic for other types
        let isMusicSneak = coordinator.sneakPeek.type == .music && vm.notchState == .closed && !vm.hideOnClosed && style == .standard
        let isTimerSneak = coordinator.sneakPeek.type == .timer && !vm.hideOnClosed && style == .standard
        let isReminderSneak = coordinator.sneakPeek.type == .reminder && !vm.hideOnClosed && style == .standard
        let isOtherSneak = coordinator.sneakPeek.type != .music && coordinator.sneakPeek.type != .timer && coordinator.sneakPeek.type != .reminder && vm.notchState == .closed
        
        return isMusicSneak || isTimerSneak || isReminderSneak || isOtherSneak
    }

    private func resolvedSneakPeekStyle() -> SneakPeekStyle {
        return coordinator.sneakPeek.styleOverride ?? Defaults[.sneakPeekStyles]
    }
}
