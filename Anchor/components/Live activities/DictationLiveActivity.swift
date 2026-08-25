/*
 * Atoll (DynamicIsland)
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

import Defaults
import SwiftUI

/// Notch live activity shown while push-to-talk dictation is running:
/// a mic on the left wing, a level meter and live transcript on the right.
struct DictationLiveActivity: View {
    @EnvironmentObject var vm: AnchorViewModel
    @ObservedObject private var dictation = DictationManager.shared

    private let wingSpacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            leadingWing
                .frame(width: wingWidth, height: vm.effectiveClosedNotchHeight)

            Rectangle()
                .fill(Color.black)
                .frame(width: vm.closedNotchSize.width)

            trailingWing
                .frame(width: wingWidth, height: vm.effectiveClosedNotchHeight)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Wings

    private var leadingWing: some View {
        HStack(spacing: wingSpacing) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: dictation.state == .listening)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
    }

    @ViewBuilder
    private var trailingWing: some View {
        HStack(spacing: wingSpacing) {
            Spacer(minLength: 0)

            switch dictation.state {
            case .preparing:
                Text("Starting…")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            case .listening:
                ListeningReadout(live: dictation.live, tint: tint)
            case .transcribing:
                Text("Transcribing…")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .trailing)
            case .idle:
                EmptyView()
            }
        }
        .padding(.trailing, 10)
        .animation(.smooth(duration: 0.2), value: dictation.state)
    }

    // MARK: - Derived state

    private var wingWidth: CGFloat {
        max(60, (vm.closedNotchSize.width * 0.6))
    }

    private var iconName: String {
        switch dictation.state {
        case .failed: return "exclamationmark.triangle.fill"
        case .transcribing: return "waveform"
        default: return "mic.fill"
        }
    }

    private var tint: Color {
        switch dictation.state {
        case .failed: return .orange
        case .listening: return .red
        default: return .white
        }
    }

    private var accessibilityDescription: String {
        switch dictation.state {
        case .idle: return ""
        case .preparing: return String(localized: "Starting dictation")
        case .listening: return String(localized: "Listening")
        case .transcribing: return String(localized: "Transcribing dictation")
        case .failed(let message): return message
        }
    }
}

/// The meter-or-transcript half of the listening state.
///
/// Split out so it is the *only* thing observing `DictationManager.LiveOutput`.
/// Both of those values change many times a second; keeping them out of the
/// parent stops the whole live activity — and the notch above it — from
/// re-rendering at meter rate.
private struct ListeningReadout: View {
    @ObservedObject var live: DictationManager.LiveOutput
    let tint: Color

    var body: some View {
        let preview = live.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.isEmpty {
            LevelMeter(level: live.inputLevel, tint: tint)
                .frame(width: 34, height: 12)
        } else {
            Text(preview)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 160, alignment: .trailing)
                .accessibilityLabel(preview)
        }
    }
}

/// Simple five-bar level meter driven by the dictation input level.
private struct LevelMeter: View {
    let level: Float
    let tint: Color

    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(tint.opacity(opacity(for: index)))
                    .frame(width: 3, height: height(for: index))
            }
        }
        .animation(.smooth(duration: 0.12), value: level)
    }

    /// Bars nearer the middle react to quieter input, giving a symmetric bloom.
    private func normalized(for index: Int) -> CGFloat {
        let distanceFromCenter = abs(CGFloat(index) - CGFloat(barCount - 1) / 2)
        let threshold = distanceFromCenter / CGFloat(barCount)
        return max(0, min(1, (CGFloat(level) - threshold) / max(0.001, 1 - threshold)))
    }

    private func height(for index: Int) -> CGFloat {
        3 + normalized(for: index) * 9
    }

    private func opacity(for index: Int) -> Double {
        0.35 + Double(normalized(for: index)) * 0.65
    }
}
