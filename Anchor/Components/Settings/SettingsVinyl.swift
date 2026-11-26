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
    @Default(.vinylWindowLevel) private var level
    @Default(.vinylShowStylus) private var showStylus
    @Default(.vinylShowProgress) private var showProgress
    @Default(.vinylProgressStyle) private var progressStyle
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
                Text("Drag the widget to move it. Drag an edge or corner to resize it. The layout follows the window’s shape and hides track details when space is tight.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if enabled {
                Section("Placement") {
                    Picker("Layer", selection: $level) {
                        ForEach(VinylWindowLevel.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .settingsHighlight(id: highlightID("Layer"))
                    .settingsInfo("Below all windows keeps it on the wallpaper, out of the way.")
                }

                Section("Look") {
                    Toggle("Show the tonearm", isOn: $showStylus)
                        .settingsHighlight(id: highlightID("Show the tonearm"))
                        .settingsInfo("Swings onto the record while playing and lifts when it stops.")

                    Picker("Show progress", selection: Binding<VinylProgressStyle?>(
                        get: { showProgress ? progressStyle : nil },
                        set: { style in
                            if let style { progressStyle = style }
                            showProgress = style != nil
                        }
                    )) {
                        Text("Off").tag(nil as VinylProgressStyle?)
                        Text("Bar").tag(Optional(VinylProgressStyle.bar))
                        Text("Ring").tag(Optional(VinylProgressStyle.ring))
                    }
                    .settingsHighlight(id: highlightID("Show progress"))
                    .settingsInfo("Ring goes around the record. Bar shows elapsed and remaining time and lets you click to seek.")

                    Toggle("Tint with the album colour", isOn: $useAlbumColor)
                        .settingsHighlight(id: highlightID("Tint with the album colour"))

                    Slider(value: $backgroundOpacity, in: 0...1) {
                        Text("Backing")
                    } minimumValueLabel: {
                        Text("None").font(.caption)
                    } maximumValueLabel: {
                        Text("Solid").font(.caption)
                    }
                    .settingsHighlight(id: highlightID("Backing"))
                    .settingsInfo("Sets the opacity of the panel behind the record and controls. At None, your wallpaper shows through.")
                }
            }
        }
    }
}
