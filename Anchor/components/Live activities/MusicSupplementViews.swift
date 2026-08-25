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
import SwiftUI

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

// Supplementary content for the music live activity: the small secondary
// readout that shares the closed notch with a playing track (a running timer,
// a reminder, a recording dot, a Focus mode, or the Caps Lock label), plus the
// width maths that decides whether it fits.
//
// Split out of ContentView.swift, which was 2,456 lines.

enum MusicSecondaryLiveActivity: Equatable {
    case timer
    case reminder(ReminderLiveActivityManager.ReminderEntry)
    case recording
    case focus(FocusModeType)
    case capsLock(showLabel: Bool)

    var id: String {
        switch self {
        case .timer:
            return "timer"
        case .reminder(let entry):
            return "reminder-\(entry.id)"
        case .recording:
            return "recording"
        case .focus(let mode):
            return "focus-\(mode.rawValue)"
        case .capsLock(let showLabel):
            return showLabel ? "caps-lock-label" : "caps-lock-icon"
        }
    }
}

struct MusicTimerSupplementView: View {
    @ObservedObject var timerManager: TimerManager
    let accentColor: Color
    let showsCountdown: Bool
    let showsProgress: Bool
    let progressStyle: TimerProgressStyle
    let notchHeight: CGFloat

    private var clampedProgress: Double {
        min(max(timerManager.progress, 0), 1)
    }

    private var showsRingProgress: Bool {
        showsProgress && progressStyle == .ring
    }

    private var showsBarProgress: Bool {
        showsProgress && progressStyle == .bar
    }

    private var countdownText: String {
        timerManager.formattedRemainingTime()
    }

    private var countdownTextWidth: CGFloat {
        max(1, TimerSupplementMetrics.countdownTextWidth(for: countdownText))
    }

    private var countdownFrameWidth: CGFloat {
        TimerSupplementMetrics.countdownFrameWidth(for: countdownText)
    }

    private var timerNameFrameWidth: CGFloat {
        TimerSupplementMetrics.timerNameFrameWidth(for: timerManager.timerName)
    }

    private var ringDiameter: CGFloat {
        max(min(notchHeight - 4, 26), 20)
    }

    var body: some View {
        HStack(spacing: showsRingProgress && showsCountdown ? 8 : 0) {
            if showsRingProgress {
                ringView
            }

            if showsCountdown {
                countdownStack
            } else if showsBarProgress {
                standaloneBarView
            } else {
                timerNameView
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var countdownStack: some View {
        VStack(alignment: .trailing, spacing: showsBarProgress ? 4 : 0) {
            Text(countdownText)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(timerManager.isOvertime ? .red : .white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.25), value: timerManager.remainingTime)
                .frame(width: countdownFrameWidth, alignment: .trailing)

            if showsBarProgress {
                barView(width: countdownTextWidth)
            }
        }
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var ringView: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.25), value: clampedProgress)
        }
        .frame(width: ringDiameter, height: ringDiameter)
        .frame(width: max(ringDiameter + 4, 30), height: notchHeight, alignment: .center)
    }

    private var standaloneBarView: some View {
        barView(width: 68)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var timerNameView: some View {
        Text(timerManager.timerName)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
            .frame(width: timerNameFrameWidth, alignment: .trailing)
    }

    private func barView(width: CGFloat) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.15))
            .frame(width: width, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(accentColor)
                    .frame(width: width * max(0, CGFloat(clampedProgress)), height: 4)
                    .animation(.smooth(duration: 0.25), value: clampedProgress)
            }
    }

}

struct MusicReminderSupplementView: View {
    let entry: ReminderLiveActivityManager.ReminderEntry
    let now: Date
    let style: ReminderPresentationStyle
    let accent: Color
    let notchHeight: CGFloat

    var body: some View {
        Group {
            switch style {
            case .ringCountdown:
                ringCountdownView
            case .digital:
                digitalCountdownView
            case .minutes:
                minutesCountdownView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private var ringCountdownView: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progressValue)
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.25), value: progressValue)
        }
        .frame(width: ringDiameter, height: ringDiameter)
        .frame(width: max(ringDiameter + 4, 26), height: notchHeight, alignment: .center)
    }

    private var digitalCountdownView: some View {
        Text(digitalCountdownText)
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundColor(accent)
            .contentTransition(.numericText())
            .animation(.smooth(duration: 0.25), value: digitalCountdownText)
            .frame(width: digitalFrameWidth, alignment: .trailing)
            .frame(height: notchHeight, alignment: .center)
    }

    private var minutesCountdownView: some View {
        Text(minutesCountdownText)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(accent)
            .frame(width: minutesFrameWidth, alignment: .trailing)
            .frame(height: notchHeight, alignment: .center)
    }

    private var progressValue: Double {
        guard entry.leadTime > 0 else { return 1 }
        let remaining = max(entry.event.start.timeIntervalSince(now), 0)
        let elapsed = entry.leadTime - remaining
        return min(max(elapsed / entry.leadTime, 0), 1)
    }

    private var digitalCountdownText: String {
        ReminderSupplementMetrics.digitalCountdownText(for: entry, now: now)
    }

    private var minutesCountdownText: String {
        ReminderSupplementMetrics.minutesCountdownText(for: entry, now: now)
    }

    private var ringDiameter: CGFloat {
        ReminderSupplementMetrics.ringDiameter(for: notchHeight)
    }

    private var digitalFrameWidth: CGFloat {
        ReminderSupplementMetrics.digitalFrameWidth(for: digitalCountdownText)
    }

    private var minutesFrameWidth: CGFloat {
        ReminderSupplementMetrics.minutesFrameWidth(for: minutesCountdownText)
    }
}

struct MusicCapsLockLabelView: View {
    let color: Color

    var body: some View {
        Text("Caps Lock")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentTransition(.opacity)
    }
}

#if canImport(AppKit)
typealias MusicSupplementFont = NSFont
#elseif canImport(UIKit)
typealias MusicSupplementFont = UIFont
#endif

enum TimerSupplementMetrics {
    static func countdownTextWidth(for text: String) -> CGFloat {
        // Measure with a fully monospaced font (matching the `.monospaced` design used
        // to render) so hour-format times like 1:00:00 aren't under-measured and clipped.
        musicMeasureText(text, font: MusicSupplementFont.monospacedSystemFont(ofSize: 13, weight: .semibold))
    }

    static func countdownFrameWidth(for text: String) -> CGFloat {
        max(countdownTextWidth(for: text) + 16, 72)
    }

    static func timerNameFrameWidth(for text: String) -> CGFloat {
        guard !text.isEmpty else { return 64 }
        let width = musicMeasureText(text, font: MusicSupplementFont.systemFont(ofSize: 12, weight: .medium))
        return max(width + 14, 64)
    }
}

enum ReminderSupplementMetrics {
    static func digitalCountdownText(for entry: ReminderLiveActivityManager.ReminderEntry, now: Date) -> String {
        let remaining = max(entry.event.start.timeIntervalSince(now), 0)
        let totalSeconds = Int(remaining.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func minutesCountdownText(for entry: ReminderLiveActivityManager.ReminderEntry, now: Date) -> String {
        let remaining = max(entry.event.start.timeIntervalSince(now), 0)
        let minutes = max(1, Int(ceil(remaining / 60)))
        return minutes == 1 ? "in 1 min" : "in \(minutes) min"
    }

    static func digitalFrameWidth(for text: String) -> CGFloat {
        let width = musicMeasureText(text, font: MusicSupplementFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold))
        return max(width + 18, 76)
    }

    static func minutesFrameWidth(for text: String) -> CGFloat {
        let width = musicMeasureText(text, font: MusicSupplementFont.systemFont(ofSize: 13, weight: .semibold))
        return max(width + 18, 88)
    }

    static func ringDiameter(for notchHeight: CGFloat) -> CGFloat {
        max(min(notchHeight - 12, 22), 16)
    }
}

func musicMeasureText(_ text: String, font: MusicSupplementFont) -> CGFloat {
    guard !text.isEmpty else { return 0 }
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    return CGFloat(ceil(NSAttributedString(string: text, attributes: attributes).size().width))
}
