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

import AppKit
import Combine
import Defaults
import Foundation

/// Hides menu bar items behind a divider, the way Ice, Bartender and Hidden Bar
/// do.
///
/// ## How this is possible at all
///
/// There is no API for hiding *another* app's status item, and there is no
/// private one worth taking either. What every app in this category actually
/// does is exploit the menu bar's layout: items are laid out right to left, so
/// an item that makes itself enormously wide pushes everything to its left off
/// the edge of the screen. This owns two ordinary `NSStatusItem`s and changes
/// their `length`. Nothing is injected into another process, nothing is
/// swizzled, and no entitlement or TCC grant is involved.
///
/// The consequence to understand is that **the user arranges their own menu
/// bar**: ⌘-dragging icons to the left or right of Anchor's divider is what
/// decides whether they hide. macOS persists both their positions and the
/// divider's through `autosaveName`, so it survives restarts.
///
/// ## Cost
///
/// Two status items and, when auto-hide is on, one one-shot timer per reveal.
/// Nothing polls, and with the feature off nothing is created at all.
@MainActor
final class MenuBarShrinkManager: ObservableObject {
    static let shared = MenuBarShrinkManager()

    /// Wide enough to push anything to its left off any display Anchor
    /// supports, and far short of a value that could overflow layout maths.
    private static let collapsedLength: CGFloat = 10_000
    private static let expandedLength: CGFloat = 22

    @Published private(set) var isCollapsed = true
    @Published private(set) var isActive = false

    /// The main divider. Items dragged to its left hide when collapsed.
    private var divider: NSStatusItem?
    /// The optional second divider. Items to *its* left stay hidden even when
    /// the first is expanded — Ice calls this the "always hidden" section.
    private var alwaysHiddenDivider: NSStatusItem?

    private var autoHideTimer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        Defaults.publisher(.enableMenuBarShrink)
            .sink { [weak self] change in
                Task { @MainActor in
                    change.newValue ? self?.activate() : self?.deactivate()
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.menuBarAlwaysHiddenSection)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncAlwaysHiddenDivider() }
            }
            .store(in: &cancellables)

        if Defaults[.enableMenuBarShrink] { activate() }
    }

    private func activate() {
        guard divider == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: Self.expandedLength)
        // The autosave name is what makes the user's chosen position stick
        // across restarts. Changing this string moves everyone's divider back
        // to the default position, so it must not be edited casually.
        item.autosaveName = "AnchorMenuBarDivider"
        item.button?.image = Self.chevron(collapsed: true)
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(dividerClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = String(
            localized: "Click to show or hide menu bar items to the left")
        divider = item

        isActive = true
        isCollapsed = true
        applyLengths()
        syncAlwaysHiddenDivider()
    }

    private func deactivate() {
        cancelAutoHide()
        if let divider { NSStatusBar.system.removeStatusItem(divider) }
        if let alwaysHiddenDivider {
            NSStatusBar.system.removeStatusItem(alwaysHiddenDivider)
        }
        divider = nil
        alwaysHiddenDivider = nil
        isActive = false
    }

    private func syncAlwaysHiddenDivider() {
        guard isActive else { return }

        if Defaults[.menuBarAlwaysHiddenSection] {
            guard alwaysHiddenDivider == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: Self.collapsedLength)
            item.autosaveName = "AnchorMenuBarAlwaysHiddenDivider"
            item.button?.image = Self.chevron(collapsed: true)
            item.button?.imagePosition = .imageOnly
            item.button?.toolTip = String(
                localized: "Items to the left of this are always hidden")
            alwaysHiddenDivider = item
        } else if let existing = alwaysHiddenDivider {
            NSStatusBar.system.removeStatusItem(existing)
            alwaysHiddenDivider = nil
        }
    }

    // MARK: - Toggling

    @objc private func dividerClicked() {
        toggle()
    }

    func toggle() {
        guard isActive else { return }
        isCollapsed.toggle()
        applyLengths()

        if isCollapsed {
            cancelAutoHide()
        } else {
            scheduleAutoHide()
        }
    }

    func collapse() {
        guard isActive, !isCollapsed else { return }
        isCollapsed = true
        cancelAutoHide()
        applyLengths()
    }

    private func applyLengths() {
        divider?.length = isCollapsed ? Self.collapsedLength : Self.expandedLength
        divider?.button?.image = Self.chevron(collapsed: isCollapsed)
        // The always-hidden divider never expands from a click; it is only
        // reachable by turning the section off.
        alwaysHiddenDivider?.length = Self.collapsedLength
    }

    // MARK: - Auto-hide

    /// One-shot, armed only while the section is showing.
    ///
    /// A repeating timer would tick for the 99% of the time the bar is
    /// collapsed and nothing needs deciding.
    private func scheduleAutoHide() {
        cancelAutoHide()
        let seconds = Defaults[.menuBarAutoHideSeconds]
        guard seconds > 0 else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Double(seconds), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.collapse()
        }
        autoHideTimer = timer
        timer.resume()
    }

    private func cancelAutoHide() {
        autoHideTimer?.cancel()
        autoHideTimer = nil
    }

    // MARK: - Glyph

    /// The chevron points the way the click will move things: right while
    /// collapsed (reveal), left while expanded (hide again).
    private static func chevron(collapsed: Bool) -> NSImage? {
        let name = collapsed ? "chevron.compact.right" : "chevron.compact.left"
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: collapsed
                ? String(localized: "Show hidden menu bar items")
                : String(localized: "Hide menu bar items"))
        image?.isTemplate = true
        return image
    }
}
