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
final class MenuBarShrinkManager: NSResponder, ObservableObject {
    static let shared = MenuBarShrinkManager()

    /// Wide enough to push anything to its left off any display Anchor
    /// supports, and far short of a value that could overflow layout maths.
    private static let collapsedLength: CGFloat = 10_000
    private static let expandedLength: CGFloat = 0
    /// The chevron's own width — it is always on screen at this size.
    private static let chevronLength: CGFloat = 24

    @Published private(set) var isCollapsed = true
    @Published private(set) var isActive = false

    /// The always-visible chevron. Clicking or hovering it toggles the section.
    ///
    /// Separate from the expander below, and that separation is the whole
    /// trick. A status item that makes itself 10,000 points wide centres its
    /// own image at ~5,000 points — which is off the screen — so a single item
    /// doing both jobs disappears exactly when it is collapsed and most needed.
    private var chevronItem: NSStatusItem?

    /// The item that does the pushing. Carries no image at all; its only job is
    /// to be wide.
    private var expanderItem: NSStatusItem?

    /// The optional second expander. Items to *its* left stay hidden even when
    /// the first section is showing — Ice calls this the "always hidden"
    /// section.
    private var alwaysHiddenDivider: NSStatusItem?

    private var autoHideTimer: DispatchSourceTimer?
    private var hoverTracking: NSTrackingArea?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private override init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

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

        Defaults.publisher(.menuBarExpandOnHover)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncHoverTracking() }
            }
            .store(in: &cancellables)

        if Defaults[.enableMenuBarShrink] { activate() }
    }

    /// Keeps Anchor's own menu bar icon out of the region Anchor's own
    /// shrinker hides.
    ///
    /// The shrinker hides items by making the divider 10,000pt wide so
    /// everything to its **left** is pushed off the screen edge, and a higher
    /// saved position sits further left (see `StatusItemDefaults`). Anchor's
    /// icon read **336** against a divider at **234** — so the shrinker was
    /// hiding Anchor's own icon, and short of turning the shrinker off there
    /// was no way for the user to get it back.
    ///
    /// Ice avoids this by construction rather than by correction: it seeds its
    /// own icon at position 0 (the far right) and its hidden divider at 1, so
    /// the divider is always immediately to the icon's left and can never
    /// sweep over it (`ControlItem.init`, Ice). Anchor's icon is a SwiftUI
    /// `MenuBarExtra`, which owns its `NSStatusItem` privately and offers no
    /// way to set an `autosaveName`, so it persists under AppKit's default
    /// name for an unnamed item — `Item-0` — and the position has to be
    /// corrected here instead of chosen at creation.
    ///
    /// Only a position that would actually be hidden is rewritten, so a
    /// placement the user chose themselves is left alone; when it is
    /// rewritten it goes to 0, Ice's own choice, which is on the visible side
    /// no matter where the divider currently sits.
    ///
    /// Must run *before* the scene builds, so AppKit reads the corrected value
    /// when it creates the item. Only the icon is ever moved, never the
    /// divider: moving the divider would change which of the user's *other*
    /// items are hidden, which is theirs to decide.
    static func keepOwnIconOnVisibleSide() {
        guard Defaults[.enableMenuBarShrink] else { return }

        // No saved divider position yet means the user has never dragged it
        // and there is nothing to be on the wrong side of.
        guard let divider = StatusItemDefaults[.preferredPosition, Self.dividerAutosaveName]
        else { return }

        // Anchor's own icon. Fragile by necessity: AppKit names unnamed status
        // items `Item-N` in creation order, and MenuBarExtra gives us no say.
        // Stable while Anchor's MenuBarExtra is its only status item without an
        // explicit autosaveName — every item this manager creates sets one.
        if Defaults[.menubarIcon] {
            pinToVisibleSide(autosaveName: "Item-0", divider: divider, position: 0)
        }

        // The chevron, which is worse to lose than the icon: it *is* the
        // control that expands and collapses the section, so once it is on the
        // hidden side the feature cannot be operated at all. Measured here at
        // 497 against a divider at 242 — i.e. hidden — even though
        // `activate()`'s own comment says the expander is created first so it
        // ends up to the chevron's left. Creation order evidently does not
        // survive whatever AppKit last persisted, so the invariant is enforced
        // rather than assumed.
        pinToVisibleSide(autosaveName: Self.chevronAutosaveName, divider: divider, position: 1)
    }

    /// Moves a status item to `position` when it would otherwise sit on the
    /// hidden side of the divider. A position the user chose that already
    /// works is left alone.
    private static func pinToVisibleSide(
        autosaveName: String, divider: CGFloat, position: CGFloat
    ) {
        if let current = StatusItemDefaults[.preferredPosition, autosaveName], current < divider {
            return
        }
        StatusItemDefaults[.preferredPosition, autosaveName] = position
    }

    /// Changing this string moves everyone's divider back to the default
    /// position, so it must not be edited casually.
    static let dividerAutosaveName = "AnchorMenuBarDivider"
    static let chevronAutosaveName = "AnchorMenuBarChevron"

    private func activate() {
        guard chevronItem == nil else { return }

        // Order matters: the expander is created first so it sits to the *left*
        // of the chevron in the menu bar's right-to-left layout, which is what
        // puts the chevron beside the visible items rather than beyond the
        // hidden ones.
        let expander = NSStatusBar.system.statusItem(withLength: Self.collapsedLength)
        expander.autosaveName = Self.dividerAutosaveName
        expander.button?.image = nil
        expanderItem = expander

        let chevron = NSStatusBar.system.statusItem(withLength: Self.chevronLength)
        chevron.autosaveName = Self.chevronAutosaveName
        chevron.button?.image = Self.chevron(collapsed: true)
        chevron.button?.imagePosition = .imageOnly
        chevron.button?.target = self
        chevron.button?.action = #selector(chevronClicked)
        chevron.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        chevron.button?.toolTip = String(
            localized: "Show or hide the menu bar items to the left")
        chevronItem = chevron

        isActive = true
        isCollapsed = true
        applyLengths()
        syncAlwaysHiddenDivider()
        syncHoverTracking()
    }

    private func deactivate() {
        cancelAutoHide()
        removeHoverTracking()
        // `removeStatusItem` deletes the item's stored preferredPosition, so
        // switching the shrinker off used to discard the user's own divider
        // placement — it reappeared at the default position next time. Ice hits
        // the same AppKit behaviour and works around it the same way, in
        // `ControlItem.deinit`.
        for item in [chevronItem, expanderItem, alwaysHiddenDivider].compactMap({ $0 }) {
            StatusItemDefaults.removeStatusItemPreservingPosition(item)
        }
        chevronItem = nil
        expanderItem = nil
        alwaysHiddenDivider = nil
        isActive = false
    }

    private func syncAlwaysHiddenDivider() {
        guard isActive else { return }

        if Defaults[.menuBarAlwaysHiddenSection] {
            guard alwaysHiddenDivider == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: Self.collapsedLength)
            item.autosaveName = "AnchorMenuBarAlwaysHiddenDivider"
            item.button?.image = nil
            item.button?.toolTip = String(
                localized: "Items to the left of this are always hidden")
            alwaysHiddenDivider = item
        } else if let existing = alwaysHiddenDivider {
            StatusItemDefaults.removeStatusItemPreservingPosition(existing)
            alwaysHiddenDivider = nil
        }
    }

    // MARK: - Hover

    /// Hover-to-expand, when the user has asked for it.
    ///
    /// `NSStatusItem` has no hover callback, so this is a tracking area on the
    /// chevron's own button. It is installed only while the setting is on —
    /// mouse tracking on a menu bar item that does not need it is pure cost.
    private func syncHoverTracking() {
        removeHoverTracking()
        guard isActive, Defaults[.menuBarExpandOnHover],
              let button = chevronItem?.button
        else { return }

        let area = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        button.addTrackingArea(area)
        hoverTracking = area
    }

    private func removeHoverTracking() {
        if let hoverTracking, let button = chevronItem?.button {
            button.removeTrackingArea(hoverTracking)
        }
        hoverTracking = nil
    }

    override func mouseEntered(with event: NSEvent) {
        guard Defaults[.menuBarExpandOnHover], isCollapsed else { return }
        setCollapsed(false)
    }

    override func mouseExited(with event: NSEvent) {
        guard Defaults[.menuBarExpandOnHover] else { return }
        // The auto-hide timer already handles re-collapsing; leaving on exit
        // would make the section impossible to click into.
        scheduleAutoHide()
    }

    // MARK: - Toggling

    @objc private func chevronClicked() {
        toggle()
    }

    func toggle() {
        guard isActive else { return }
        setCollapsed(!isCollapsed)
    }

    func collapse() {
        guard isActive, !isCollapsed else { return }
        setCollapsed(true)
    }

    private func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        applyLengths()
        if collapsed { cancelAutoHide() } else { scheduleAutoHide() }
    }

    private func applyLengths() {
        expanderItem?.length = isCollapsed ? Self.collapsedLength : Self.expandedLength
        chevronItem?.button?.image = Self.chevron(collapsed: isCollapsed)
        // The always-hidden expander never opens from a click; it is only
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
