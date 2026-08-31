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

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let clipboardHistoryPanel = Self("clipboardHistoryPanel", default: .init(.c, modifiers: [.shift, .command]))
    /// Opens the application launcher panel.
    static let toggleLauncher = Self("toggleLauncher", default: .init(.space, modifiers: [.option]))
    /// Push-to-talk: hold to dictate, release to paste the transcript.
    static let pushToTalkDictation = Self("pushToTalkDictation", default: .init(.d, modifiers: [.shift, .command]))
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))
    static let toggleTerminalTab = Self("toggleTerminalTab", default: .init(.backtick, modifiers: [.control]))
    static let startDemoTimer = Self("startDemoTimer", default: .init(.t, modifiers: [.command, .shift]))
    /// Opens the system eyedropper and copies the picked colour.
    static let pickColor = Self("pickColor", default: .init(.p, modifiers: [.command, .shift]))
    /// Opens the ring-shaped application switcher.
    ///
    /// Option-Tab rather than Command-Tab: taking over ⌘Tab means swallowing it
    /// with an event tap, and an app that swallows ⌘Tab and then hangs leaves
    /// the user with no way to switch apps at all. The system switcher stays
    /// where it is and this sits beside it.
    static let appSwitcher = Self("appSwitcher", default: .init(.tab, modifiers: [.option]))
    /// Opens the ring going *backwards*, and steps backwards while it is open —
    /// ⌥⇧Tab, mirroring ⌘⇧Tab in the system switcher.
    ///
    /// This has to be its own registered shortcut rather than falling out of
    /// the Shift modifier on `appSwitcher`. `KeyboardShortcuts` matches an
    /// exact modifier set, so ⌥⇧Tab is simply not ⌥Tab and never fired it:
    /// with the ring closed, pressing ⌥⇧Tab did nothing in Anchor at all and
    /// the keystroke fell through to whatever app was focused, where ⇧Tab
    /// moves focus backwards — which is what "reversing affects the window I
    /// am working on" actually was. `AppSwitcherPanelManager.invoke(reverse:)`
    /// had supported this from the start; nothing ever passed `true`.
    static let appSwitcherReverse = Self(
        "appSwitcherReverse", default: .init(.tab, modifiers: [.option, .shift]))
    /// Shows or hides the menu bar items behind Anchor's divider.
    static let toggleMenuBarSection = Self("toggleMenuBarSection", default: .init(.m, modifiers: [.option, .command]))
    /// Pins the notch open, so it stops closing on hover-out or a click
    /// elsewhere. Press again to unpin and let it close normally.
    static let togglePinNotch = Self("togglePinNotch", default: .init(.k, modifiers: [.command, .shift]))
}
