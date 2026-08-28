/*
 * Anchor
 * Per-app audio engine, derived from FineTune (github.com/ronitsingh10/FineTune).
 * Copyright (C) 2026 Ronit Singh
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

import AppKit

/// Applies the device-icon display precedence:
/// user override → automatic icon (driver image or suggested SF Symbol).
enum DeviceIconResolver {
    /// An override symbol that fails to resolve (hand-edited settings.json,
    /// symbol removed in a future macOS) falls back to the automatic icon
    /// rather than producing a blank glyph.
    static func displayIcon(
        overrideSymbol: String?,
        automatic: NSImage?,
        deviceName: String
    ) -> NSImage? {
        if let overrideSymbol,
           let image = NSImage(systemSymbolName: overrideSymbol, accessibilityDescription: deviceName) {
            return image
        }
        return automatic
    }
}
