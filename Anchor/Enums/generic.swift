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

import Foundation
import Defaults
import CoreGraphics

public enum Style {
    case notch
    case floating
}

/// Controls how Atoll renders on external and non-notched displays.
/// - `notch`: Standard notch shape (concave top corners blending into the screen edge).
/// - `dynamicIsland`: Pill-shaped island with continuously rounded corners,
///   inspired by DynamicNotchKit's floating style. Only applies to screens
///   that do NOT have a physical notch.
enum ExternalDisplayStyle: String, CaseIterable, Defaults.Serializable, Identifiable {
    case notch = "Standard Notch"
    case dynamicIsland = "Dynamic Island"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .notch:
            return String(localized: "Standard Notch")
        case .dynamicIsland:
            return String(localized: "Dynamic Island")
        }
    }

    var description: String {
        switch self {
        case .notch:
            return String(localized: "Classic notch shape that blends into the top screen edge")
        case .dynamicIsland:
            return String(localized: "Pill-shaped island with rounded corners, similar to iPhone's Dynamic Island")
        }
    }
}

public enum ContentType: Int, Codable, Hashable, Equatable {
    case normal
    case menu
    case settings
}

public enum NotchState {
    case closed
    case open
}

public enum NotchViews {
    case home
    case timer
    case notes
    case clipboard
    case terminal
    case lyrics
    case shelf
    case stats
    case notifications
    case todo
    case cameraMirror
    case gemini
}

enum NotesLayoutState: Equatable {
    case list
    case split
    case editor

    var preferredHeight: CGFloat {
        switch self {
        case .list:
            return 240
        case .split:
            return 260
        case .editor:
            return 320
        }
    }
}


enum DownloadIndicatorStyle: String, Defaults.Serializable {
    case progress = "Progress"
    case percentage = "Percentage"
    case circle = "Circle"
    
    var localizedName: String {
        switch self {
            case .progress:
                return String(localized: "Progress")
            case .percentage:
                return String(localized: "Percentage")
            case .circle:
                return String(localized: "Circle")
        }
    }
}

enum DownloadIconStyle: String, CaseIterable, Defaults.Serializable {
    case onlyAppIcon = "Only app icon"
    case onlyIcon = "Only download icon"
    case iconAndAppIcon = "Icon and app icon"
}


enum WindowHeightMode: String, Defaults.Serializable {
    case matchMenuBar = "Match menubar height"
    case matchRealNotchSize = "Match real notch height"
    case custom = "Custom height"
}

enum SliderColorEnum: String, CaseIterable, Defaults.Serializable {
    case white = "White"
    case albumArt = "Match album art"
    case accent = "Accent color"
    
    var localizedName: String {
        switch self {
            case .white:
                return String(localized: "White")
            case .albumArt:
                return String(localized: "Match album art")
            case .accent:
                return String(localized: "Accent color")
        }
    }
}

enum LockScreenGlassStyle: String, CaseIterable, Defaults.Serializable, Identifiable {
    case liquid = "Liquid Glass"
    case frosted = "Frosted Glass"
    
    var id: String { rawValue }
    
    var localizedName: String {
        switch self {
        case .liquid:
            return String(localized: "Liquid Glass")
        case .frosted:
            return String(localized: "Frosted Glass")
        }
    }
}

enum LockScreenGlassCustomizationMode: String, CaseIterable, Defaults.Serializable, Identifiable {
    case standard = "Standard"
    case customLiquid = "Custom Liquid"

    var id: String { rawValue }

    var allowsVariantSelection: Bool {
        self == .customLiquid
    }
    
    var localizedName: String {
        switch self {
            case .standard:
                return String(localized: "Standard")
            case .customLiquid:
                return String(localized: "Custom Liquid")
        }
    }
}

enum LockScreenTimerSurfaceMode: String, CaseIterable, Defaults.Serializable, Identifiable {
    case classic = "Classic"
    case glass = "Glass"

    var id: String { rawValue }
    
    var localizedName: String {
        switch self {
        case .classic:
            return String(localized: "Classic")
        case .glass:
            return String(localized: "Glass")
        }
    }
}

enum LockScreenWeatherWidgetStyle: String, CaseIterable, Defaults.Serializable, Identifiable {
    case inline = "Inline"
    case circular = "Circular"

    var id: String { rawValue }
    
    var localizedName: String {
        switch self {
        case .inline:
            return String(localized: "Inline")
        case .circular:
            return String(localized: "Circular")
        }
    }
}

enum LockScreenWeatherProviderSource: String, CaseIterable, Defaults.Serializable, Identifiable {
    case wttr = "wttr.in"
    case openMeteo = "Open Meteo"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var supportsAirQuality: Bool {
        switch self {
        case .wttr:
            return false
        case .openMeteo:
            return true
        }
    }
}

enum LockScreenWeatherTemperatureUnit: String, CaseIterable, Defaults.Serializable, Identifiable {
    case celsius = "Celsius"
    case fahrenheit = "Fahrenheit"

    var id: String { rawValue }

    var usesMetricSystem: Bool { self == .celsius }

    var symbol: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }

    var openMeteoTemperatureParameter: String? {
        switch self {
        case .celsius: return nil
        case .fahrenheit: return "fahrenheit"
        }
    }

    var localizedName: String {
        switch self {
        case .celsius: return String(localized: "Celsius")
        case .fahrenheit: return String(localized: "Fahrenheit")
        }
    }
}

enum LockScreenWeatherAirQualityScale: String, CaseIterable, Defaults.Serializable, Identifiable {
    case us = "U.S. AQI"
    case european = "EAQI"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var compactLabel: String {
        switch self {
        case .us:
            return String(localized: "AQI")
        case .european:
            return String(localized: "EAQI")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .us:
            return String(localized: "AQI")
        case .european:
            return String(localized: "EAQI")
        }
    }

    var queryParameter: String {
        switch self {
        case .us:
            return "us_aqi"
        case .european:
            return "european_aqi"
        }
    }

    var gaugeRange: ClosedRange<Double> {
        switch self {
        case .us:
            return 0...500
        case .european:
            return 0...120
        }
    }
}

enum LockScreenReminderChipStyle: String, CaseIterable, Defaults.Serializable, Identifiable {
    case eventColor = "Event color"
    case monochrome = "White"

    var id: String { rawValue }
    
    var localizedName: String {
            switch self {
            case .eventColor:
                return String(localized: "Event color")
            case .monochrome:
                return String(localized: "White")
            }
        }
}

enum TimerInputStyle: String, CaseIterable, Defaults.Serializable, Identifiable {
    case ruler = "Ruler"
    case manual = "Manual"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .ruler: return String(localized: "Ruler")
        case .manual: return String(localized: "Manual")
        }
    }
}


/// How the per-app volume control behaves.
///
/// Two shapes for the same underlying gain, because they answer different
/// questions: "how loud should this app be relative to the others" versus
/// "make this quiet app louder than the system can".
enum PerAppVolumeMode: String, CaseIterable, Defaults.Serializable, Identifiable {
    /// Four steps including silence: muted, regular, loud, louder. Silence is a
    /// step, so there is no separate mute button.
    case presets = "Preset volumes"
    /// Three steps, all at or above normal, with mute as its own control.
    case booster = "Volume booster"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .presets: return String(localized: "Preset volumes")
        case .booster: return String(localized: "Volume booster")
        }
    }

    var detail: String {
        switch self {
        case .presets:
            return String(localized: "Four steps: muted, regular, loud, louder. Clicking through them includes silence, so no separate mute button is shown.")
        case .booster:
            return String(localized: "Three steps, none below normal, for making a quiet app louder. Mute is a separate button.")
        }
    }

    /// Gain for each step, in order.
    var levels: [Float] {
        switch self {
        case .presets: return [0.0, 1.0, 1.5, 2.0]
        case .booster: return [1.0, 1.5, 2.0]
        }
    }

    /// Icon for each step. Index 0 of `.presets` is silence.
    var symbols: [String] {
        switch self {
        case .presets: return ["speaker.slash.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"]
        case .booster: return ["speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"]
        }
    }
}


/// How the launcher grid is paged.
enum LauncherNavigationStyle: String, CaseIterable, Defaults.Serializable, Identifiable {
    case pages       = "Page dots"
    case scrollBar   = "Scroll bar"
    case both        = "Both"

    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .pages: return String(localized: "Page dots")
        case .scrollBar: return String(localized: "Scroll bar")
        case .both: return String(localized: "Both")
        }
    }
    var showsDots: Bool { self != .scrollBar }
    var showsBar: Bool { self != .pages }
}

/// Which view the launcher shows when, relative to what has been typed.
enum LauncherLayoutMode: String, CaseIterable, Defaults.Serializable, Identifiable {
    /// Grid of every app with an empty query; a list once you type.
    case gridWhenEmpty = "Grid when empty"
    /// The inverse: a list of recents with an empty query, a grid of matches
    /// once you type.
    case listWhenEmpty = "List when empty"

    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .gridWhenEmpty: return String(localized: "Grid when empty, list when typing")
        case .listWhenEmpty: return String(localized: "List when empty, grid when typing")
        }
    }

    /// Whether the grid should be shown for a given query state.
    func showsGrid(queryIsEmpty: Bool) -> Bool {
        switch self {
        case .gridWhenEmpty: return queryIsEmpty
        case .listWhenEmpty: return !queryIsEmpty
        }
    }
}

/// How apps are ordered in the launcher grid.
enum LauncherSortMode: String, CaseIterable, Defaults.Serializable, Identifiable {
    /// The user's own order, set by dragging. Anything not placed keeps its
    /// alphabetical position after the ones that were.
    case custom       = "Custom"
    case alphabetical = "Alphabetical"
    case mostUsed     = "Most used"
    case mostRecent   = "Most recent"

    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .custom: return String(localized: "Custom")
        case .alphabetical: return String(localized: "Alphabetical")
        case .mostUsed: return String(localized: "Most used")
        case .mostRecent: return String(localized: "Most recent")
        }
    }

    /// Dragging only means something when the order is the user's to set.
    var isReorderable: Bool { self == .custom }
}
