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

struct VinylSettings: View {
    @Default(.enableVinylWidget) private var enabled
    @Default(.vinylWidgetSize) private var size
    @Default(.vinylWindowLevel) private var level
    @Default(.vinylShowStylus) private var showStylus
    @Default(.vinylShowProgress) private var showProgress
    @Default(.vinylProgressStyle) private var progressStyle
    @Default(.vinylShowTitle) private var showTitle
    @Default(.vinylUseAlbumColor) private var useAlbumColor
    @Default(.vinylBackgroundOpacity) private var backgroundOpacity

    private func highlightID(_ title: String) -> String {
        SettingsTab.vinyl.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableVinylWidget) {
                    Text("Show the vinyl widget")
                }
                .settingsHighlight(id: highlightID("Show the vinyl widget"))
            } footer: {
                Text(
                    "A record on the desktop that turns while music plays, with "
                    + "the album art as its label. Drag it anywhere; it comes back "
                    + "where you left it.\n\n"
                    + "The rotation is a Core Animation handed to the render "
                    + "server, not a per-frame redraw, so a spinning record costs "
                    + "Anchor nothing while it turns. It stops entirely when "
                    + "playback pauses and the window is torn down while the "
                    + "display sleeps.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Placement") {
                Picker("Size", selection: $size) {
                    ForEach(VinylWidgetSize.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .disabled(!enabled)
                .settingsHighlight(id: highlightID("Size"))

                Picker("Layer", selection: $level) {
                    ForEach(VinylWindowLevel.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .disabled(!enabled)
                .settingsHighlight(id: highlightID("Layer"))
                .settingsInfo("Below all windows keeps it on the wallpaper, out of the way.")
            }

            Section("Look") {
                Toggle("Show the tonearm", isOn: $showStylus)
                    .disabled(!enabled)
                    .settingsHighlight(id: highlightID("Show the tonearm"))
                    .settingsInfo("Swings onto the record while playing and lifts when it stops.")

                Toggle("Show progress", isOn: $showProgress)
                    .disabled(!enabled)
                    .settingsHighlight(id: highlightID("Show progress"))

                Picker("Progress style", selection: $progressStyle) {
                    ForEach(VinylProgressStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                .disabled(!enabled || !showProgress)
                .settingsHighlight(id: highlightID("Progress style"))
                .settingsInfo("The ring hugs the record and covers nothing. The bar sits under the transport with elapsed and remaining times, and can be clicked to seek.")

                Toggle("Show title and artist", isOn: $showTitle)
                    .disabled(!enabled)
                    .settingsHighlight(id: highlightID("Show title and artist"))

                Toggle("Tint with the album colour", isOn: $useAlbumColor)
                    .disabled(!enabled)
                    .settingsHighlight(id: highlightID("Tint with the album colour"))

                Slider(value: $backgroundOpacity, in: 0...0.85) {
                    Text("Backing")
                } minimumValueLabel: {
                    Text("None").font(.caption)
                } maximumValueLabel: {
                    Text("Solid").font(.caption)
                }
                .disabled(!enabled)
                .settingsHighlight(id: highlightID("Backing"))
                .settingsInfo("A panel behind the record, for wallpapers it would otherwise disappear into.")
            }
        }
    }
}
