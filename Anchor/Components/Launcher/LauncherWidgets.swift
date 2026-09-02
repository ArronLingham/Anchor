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

    var anyEnabled: Bool { showClock || showWeather || showVinyl }

    var body: some View {
        if anyEnabled {
            HStack(spacing: 12) {
                if showClock { LauncherClockWidget() }
                if showWeather { LauncherWeatherWidget() }
                if showVinyl { LauncherVinylWidget() }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            .padding(.bottom, 2)
        }
    }
}

/// A widget's shared shell, so the three look like one set.
private struct WidgetCard<Content: View>: View {
    var onTap: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minWidth: 108, minHeight: 62, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
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
    @ObservedObject private var music = MusicManager.shared

    var body: some View {
        WidgetCard(onTap: {
            Defaults[.enableVinylWidget] = true
            VinylWidgetWindowManager.shared.sync()
        }) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.black.opacity(0.85))
                    Image(nsImage: music.albumArt)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 26, height: 26)
                        .clipShape(Circle())
                    Circle()
                        .fill(Color.primary.opacity(0.9))
                        .frame(width: 5, height: 5)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(music.songTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(music.artistName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 140, alignment: .leading)
            }
        }
        .help("Open the vinyl player")
    }
}
