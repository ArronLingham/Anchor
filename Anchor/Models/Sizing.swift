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

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)
let batterySneakSize: CGSize = .init(width: 160, height: 1)

var openNotchSize: CGSize {
    let storedWidth = Defaults[.openNotchWidth]
    let minWidth = currentRecommendedMinimumNotchWidth()
    let maxWidth = maxAllowedNotchWidth()
    let width = min(max(storedWidth, minWidth), maxWidth)
    return .init(width: width, height: 200)
}

/// Maximum notch width based on the current screen's point width.
/// Prevents the notch from extending beyond the screen on scaled displays.
func maxAllowedNotchWidth(for screenName: String? = nil) -> CGFloat {
    let screen: NSScreen?
    if let screenName {
        screen = NSScreen.screens.first { $0.localizedName == screenName }
    } else {
        screen = NSScreen.main
    }
    guard let screenWidth = screen?.frame.width, screenWidth > 0 else {
        return 900
    }
    return max(screenWidth - 60, 400)
}

/// Convenience for the main screen.
func maxAllowedNotchWidth() -> CGFloat {
    maxAllowedNotchWidth(for: nil)
}

// MARK: - Tab-Based Notch Width

/// Counts the number of currently enabled standard notch tabs.
/// Mirrors the tab-building logic in ``TabSelectionView``.
func enabledStandardTabCount() -> Int {
    var count = 0

    // Home tab
    if Defaults[.showStandardMediaControls] || Defaults[.showCalendar] {
        count += 1
    }

    // Timer tab (only in .tab display mode)
    if Defaults[.enableTimerFeature] && Defaults[.timerDisplayMode] == .tab {
        count += 1
    }

    // Notes / Clipboard tab
    if Defaults[.enableNotes] || (Defaults[.enableClipboardManager] && Defaults[.clipboardDisplayMode] == .separateTab) {
        count += 1
    }

    // Terminal tab
    if Defaults[.enableTerminalFeature] {
        count += 1
    }

    // Lyrics tab
    if Defaults[.enableLyrics] {
        count += 1
    }

    // Shelf tab
    if Defaults[.enableShelf] {
        count += 1
    }

    // Stats tab
    if Defaults[.enableSystemStats] {
        count += 1
    }

    // Alerts / Notification tab
    if Defaults[.enableNotificationMirroring] {
        count += 1
    }

    // To-Do tab
    if Defaults[.enableTodoFeature] {
        count += 1
    }

    // Camera Mirror tab
    if Defaults[.enableCameraMirror] {
        count += 1
    }

    // Gemini AI tab
    if Defaults[.enableAIAssistant] {
        count += 1
    }

    return count
}

/// Returns the recommended minimum notch width for the given tab count.
func recommendedMinimumNotchWidth(forTabCount count: Int) -> CGFloat {
    if count >= 6 { return 740 }
    if count == 5 { return 680 }
    if count == 4 { return 620 }
    if count == 3 { return 560 }
    if count == 2 { return 520 }
    return 480
}

/// Returns the recommended minimum notch width for the current tab configuration.
func currentRecommendedMinimumNotchWidth() -> CGFloat {
    recommendedMinimumNotchWidth(forTabCount: enabledStandardTabCount())
}

/// Enforces the minimum notch width based on current tab count.
/// Also clamps to screen width so the notch never exceeds the display.
/// Only adjusts when not in minimalistic mode.
func enforceMinimumNotchWidth() {
    guard !Defaults[.enableMinimalisticUI] else { return }
    let minWidth = currentRecommendedMinimumNotchWidth()
    let maxWidth = maxAllowedNotchWidth()
    var width = Defaults[.openNotchWidth]
    if width < minWidth { width = minWidth }
    if width > maxWidth { width = maxWidth }
    if Defaults[.openNotchWidth] != width {
        Defaults[.openNotchWidth] = width
    }
}

// MARK: - Tab-Specific Dynamic Sizing

/// Calculates the per-tab dynamic notch size (both width and height vary by tab).
@MainActor
func tabSpecificNotchSize(for view: NotchViews, baseSize: CGSize, screen: NSScreen? = nil) -> CGSize {
    guard !Defaults[.enableMinimalisticUI] else {
        return baseSize
    }

    let minTabWidth = currentRecommendedMinimumNotchWidth()
    let maxAllowedW = maxAllowedNotchWidth(for: screen?.localizedName)
    let screenFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

    var width = baseSize.width
    var height = baseSize.height

    switch view {
    case .home:
        // Home tab is compact; default width does not need to be as wide as to-do or terminal
        width = min(baseSize.width, 580)
        height = 200

    case .todo:
        // To-do list needs double height and spacious width
        width = max(baseSize.width, 680)
        height = max(400, baseSize.height * 2)

    case .timer:
        // Timer tab with presets column
        width = min(max(baseSize.width, 540), 600)
        height = 250

    case .notes, .clipboard:
        // Notes split view / editor and clipboard history
        width = max(baseSize.width, 680)
        let preferred = AnchorViewCoordinator.shared.notesLayoutState.preferredHeight
        height = max(240, preferred)

    case .terminal:
        // Terminal tab: wide for 80-col shell, dynamic height based on user fraction
        width = max(baseSize.width, min(screenFrame.width - 120, 840))
        let maxFraction = Defaults[.terminalMaxHeightFraction]
        height = min(screenFrame.height * maxFraction, max(300, screenFrame.height * maxFraction))

    case .lyrics:
        // Synced lyrics view
        width = min(max(baseSize.width, 560), 660)
        height = 300

    case .shelf:
        // File drop shelf
        width = max(baseSize.width, 600)
        height = 220

    case .stats:
        // System stats graphs
        width = max(baseSize.width, 620)
        height = 220

    case .notifications:
        // Alerts & notification history
        width = max(baseSize.width, 620)
        height = 320

    case .cameraMirror:
        // Video camera mirror
        width = min(max(baseSize.width, 540), 640)
        height = 320

    case .gemini:
        // AI assistant chat interface
        width = max(baseSize.width, 680)
        height = 380
    }

    width = min(max(width, minTabWidth), maxAllowedW)
    height = min(height, max(200, screenFrame.height - 60))

    return CGSize(width: width, height: height)
}

private let minimalisticBaseOpenNotchSize: CGSize = .init(width: 420, height: 180)
private let minimalisticLyricsExtraHeight: CGFloat = 40
let minimalisticTimerCountdownTopPadding: CGFloat = 12
let minimalisticTimerCountdownContentHeight: CGFloat = 82
let minimalisticTimerCountdownBlockHeight: CGFloat = minimalisticTimerCountdownTopPadding + minimalisticTimerCountdownContentHeight
let notchShadowPaddingStandard: CGFloat = 18
let notchShadowPaddingMinimalistic: CGFloat = 12

@MainActor
func minimalisticOpenNotchSize(isDynamicIslandMode: Bool) -> CGSize {
    var size = minimalisticBaseOpenNotchSize

    if isDynamicIslandMode {
        size.width = 340 // Reduced from 420 for a narrower pill
        size.height = 144 // Exact height of the minimalistic music player view
    }

    if Defaults[.enableLyrics] {
        size.height += minimalisticLyricsExtraHeight
    }
    
    let reminderCount = ReminderLiveActivityManager.shared.activeWindowReminders.count
    if reminderCount > 0 {
        let reminderHeight = ReminderLiveActivityManager.additionalHeight(forRowCount: reminderCount)
        size.height += reminderHeight
    }

    if AnchorViewCoordinator.shared.timerLiveActivityEnabled && TimerManager.shared.isExternalTimerActive {
        size.height += minimalisticTimerCountdownBlockHeight
    }

    return size
}
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))
let minimalisticCornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 35, bottom: 35), closed: cornerRadiusInsets.closed)

// MARK: - Terminal tab clip (notch surface)

/// Padding on the terminal block inside the notch. Inner corner radius = outer shell radius on that edge, minus the matching edge padding.
let notchTerminalContentEdgePadding: (top: CGFloat, horizontal: CGFloat, bottom: CGFloat) = (4, 8, 8)

/// Inner margin (all edges) between the SwiftTerm view's glyphs and the terminal block edge.
/// Applied to the LocalProcessTerminalView frame only; the frosted blur underlay stays full-bleed.
let notchTerminalInnerTextInset: CGFloat = 6

/// Bottom radii for the shell (outer) and the terminal ``clipShape`` (inner), per design: inner = outer shell bottom radius − `notchTerminalContentEdgePadding.bottom`.
func notchTerminalBottomCornerRadii(
    isDynamicIslandMode: Bool,
    notchState: NotchState,
    cornerRadiusScaling: Bool,
    enableMinimalisticUI: Bool,
    closedNotchHeight: CGFloat
) -> (outerBottom: CGFloat, innerBottom: CGFloat) {
    let p = notchTerminalContentEdgePadding.bottom
    if isDynamicIslandMode {
        let outer: CGFloat
        if notchState == .open {
            outer = enableMinimalisticUI
                ? minimalisticCornerRadiusInsets.opened.top
                : dynamicIslandPillCornerRadiusInsets.opened
        } else {
            outer = max(closedNotchHeight / 2, dynamicIslandPillCornerRadiusInsets.closed.standard)
        }
        return (outer, max(0, outer - p))
    }
    let active: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = {
        if enableMinimalisticUI {
            return (opened: minimalisticCornerRadiusInsets.opened, closed: cornerRadiusInsets.closed)
        }
        return cornerRadiusInsets
    }()
    let outerBottom: CGFloat
    if notchState == .open && cornerRadiusScaling {
        outerBottom = active.opened.bottom
    } else {
        outerBottom = active.closed.bottom
    }
    return (outerBottom, max(0, outerBottom - p))
}


func notchShadowPaddingValue(isMinimalistic: Bool) -> CGFloat {
    isMinimalistic ? notchShadowPaddingMinimalistic : notchShadowPaddingStandard
}

func addShadowPadding(to size: CGSize, isMinimalistic: Bool) -> CGSize {
    CGSize(width: size.width, height: size.height + notchShadowPaddingValue(isMinimalistic: isMinimalistic))
}

/// Determines whether a specific screen should render the Dynamic Island pill
/// shape instead of the standard notch shape.
///
/// Returns `true` only when ALL of these conditions are met:
/// 1. The user has selected `.dynamicIsland` in `externalDisplayStyle`
/// 2. The screen does NOT have a physical notch (safeAreaInsets.top == 0)
///
/// Screens with a physical notch always use the standard notch shape.
func shouldUseDynamicIslandMode(for screenName: String?) -> Bool {
    guard Defaults[.externalDisplayStyle] == .dynamicIsland else {
        return false
    }

    var selectedScreen: NSScreen? = NSScreen.main
    if let screenName {
        selectedScreen = NSScreen.screens.first(where: { $0.localizedName == screenName })
    }

    guard let screen = selectedScreen else {
        // No screen found — fallback to standard notch
        return false
    }

    // Physical notch screens always use standard notch shape
    return screen.safeAreaInsets.top <= 0
}

/// Corner radius insets for the Dynamic Island pill shape.
/// - closed: half the closed notch height for a true capsule look
/// - opened: generous radius for smooth expanded pill
let dynamicIslandPillCornerRadiusInsets: (opened: CGFloat, closed: (standard: CGFloat, minimalistic: CGFloat)) = (
    opened: 24,
    closed: (standard: 16, minimalistic: 16)
)

/// Vertical offset from the top screen edge for the Dynamic Island pill.
/// Creates a visual gap so the pill floats below the menu bar, mimicking
/// the iPhone's Dynamic Island detachment from the physical screen edge.
let dynamicIslandTopOffset: CGFloat = 6

/// Extra horizontal padding applied OUTSIDE the pill clip shape in Dynamic
/// Island mode so the drop shadow has room to render without being clipped
/// by the outer frame constraint.
let dynamicIslandShadowInset: CGFloat = 14

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 13.0, closed: 4.0)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
}

func getScreenFrame(_ screen: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let customScreen = screen {
        selectedScreen = NSScreen.screens.first(where: { $0.localizedName == customScreen })
    }
    
    if let screen = selectedScreen {
        return screen.frame
    }
    
    return nil
}

func getClosedNotchSize(screen: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = Defaults[.closedNotchWidth]

    var selectedScreen = NSScreen.main

    if let customScreen = screen {
        selectedScreen = NSScreen.screens.first(where: { $0.localizedName == customScreen })
    }

    // Check if the screen is available
    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
            
            if Defaults[.customizePhysicalNotchWidth] {
                notchWidth = Defaults[.closedNotchWidth]
            }
        }

        // Check if the Mac has a notch
        if screen.safeAreaInsets.top > 0 {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}
