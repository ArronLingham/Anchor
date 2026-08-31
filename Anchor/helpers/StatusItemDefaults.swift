/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This file is ported from Ice (github.com/jordanbaird/Ice), GPL-3.0.
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

import Cocoa

/// Typed access to the user defaults AppKit keeps for a status item.
///
/// AppKit persists a status item's menu bar placement under
/// `"NSStatusItem Preferred Position <autosaveName>"` in the owning app's
/// defaults domain. There is no API for it — the key format is the contract —
/// so this wraps it rather than spreading interpolated string keys around.
///
/// **A higher number sits further left.** Verified against Control Center's
/// own saved positions on this machine: `BentoBox` (the Control Center icon,
/// which sits just left of the clock, i.e. far right) is 163, while `WiFi`,
/// several slots further left, is 552.
enum StatusItemDefaults {
    static subscript<Value>(key: Key<Value>, autosaveName: String) -> Value? {
        get { UserDefaults.standard.object(forKey: key.stringKey(for: autosaveName)) as? Value }
        set { UserDefaults.standard.set(newValue, forKey: key.stringKey(for: autosaveName)) }
    }

    struct Key<Value> {
        let rawValue: String

        func stringKey(for autosaveName: String) -> String {
            "NSStatusItem \(rawValue) \(autosaveName)"
        }
    }

    /// Removes a status item while preserving its stored position.
    ///
    /// `NSStatusBar.removeStatusItem` has the side effect of deleting the
    /// item's `preferredPosition`, so tearing the menu bar items down — which
    /// Anchor does whenever the shrinker is switched off — silently discarded
    /// the user's own arrangement of the divider, and it came back at the
    /// default position next time. Cache the value across the removal.
    static func removeStatusItemPreservingPosition(_ item: NSStatusItem) {
        let autosaveName = item.autosaveName as String
        let cached = Self[.preferredPosition, autosaveName]
        NSStatusBar.system.removeStatusItem(item)
        Self[.preferredPosition, autosaveName] = cached
    }
}

extension StatusItemDefaults.Key<CGFloat> {
    /// `"NSStatusItem Preferred Position <autosaveName>"`
    static let preferredPosition = Self(rawValue: "Preferred Position")
}

extension StatusItemDefaults.Key<Bool> {
    /// `"NSStatusItem Visible <autosaveName>"`
    static let visible = Self(rawValue: "Visible")
}
