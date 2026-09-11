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
    /// The chevron uses standard macOS variable length so its spacing matches all other menu bar icons.
    private static let chevronLength: CGFloat = NSStatusItem.variableLength

    @Published private(set) var isCollapsed = true
    @Published private(set) var isActive = false

    /// The always-visible chevron. Clicking or hovering it toggles the section.
    ///
    /// The chevron item is PERMANENTLY 24 points wide with native image drawing,
    /// ensuring it is ALWAYS visible and NEVER disappears regardless of whether
    /// the hidden section is expanded or collapsed.
    private var chevronItem: NSStatusItem?

    /// The item that does the pushing. Persistent while active.
    /// Created immediately to the left of the chevron (`chevronPos + 0.01`).
    /// Its length is `collapsedLength` (10,000) when collapsed and 0 when expanded.
    /// It is NEVER destroyed/recreated on toggle or when the menu bar auto-hides.
    private var expanderItem: NSStatusItem?
    private var expanderWidthConstraint: NSLayoutConstraint?

    /// The optional second expander. Items to *its* left stay hidden even when
    /// the first section is showing — Ice calls this the "always hidden"
    /// section.
    private var alwaysHiddenDivider: NSStatusItem?

    private var lastKnownChevronPos: CGFloat?
    private var rehideMonitor: Any?
    private var rehideTimer: DispatchSourceTimer?
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

        // Re-assert lengths on display/resolution changes
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.applyLengths()
                }
            }
            .store(in: &cancellables)

        if Defaults[.enableMenuBarShrink] { activate() }
    }

    /// Pre-seeds preferred positions before any scene or status item is created.
    ///
    /// The shrinker hides items by expanding an item 10,000pt wide to the
    /// left of the chevron. In AppKit status item positions, a higher saved
    /// position sits further left (see `StatusItemDefaults`).
    ///
    /// Must run *before* the scene builds, so AppKit reads the corrected value
    /// when it creates the status items.
    static func keepOwnIconOnVisibleSide() {
        guard Defaults[.enableMenuBarShrink] else { return }

        UserDefaults.standard.synchronize()

        // Read current chevron position or default to 1 (left of position 0)
        let chevronPos = StatusItemDefaults[.preferredPosition, Self.chevronAutosaveName] ?? 1
        StatusItemDefaults[.preferredPosition, Self.chevronAutosaveName] = chevronPos

        // CRITICAL: Pre-seed divider position immediately to the left of the chevron (+0.01)
        // BEFORE any status item or scene is created, so AppKit/WindowServer reads it immediately.
        StatusItemDefaults[.preferredPosition, Self.dividerAutosaveName] = chevronPos + 0.01

        // If Anchor's own icon (Item-0) has no position saved yet, seed it on the visible side (0)
        if Defaults[.menubarIcon] && StatusItemDefaults[.preferredPosition, "Item-0"] == nil {
            StatusItemDefaults[.preferredPosition, "Item-0"] = 0
        }

        UserDefaults.standard.synchronize()
    }

    static let dividerAutosaveName = "AnchorMenuBarDivider"
    static let chevronAutosaveName = "AnchorMenuBarChevron"

    private func activate() {
        guard chevronItem == nil else { return }

        UserDefaults.standard.synchronize()

        let chevronPos = StatusItemDefaults[.preferredPosition, Self.chevronAutosaveName] ?? 1
        StatusItemDefaults[.preferredPosition, Self.chevronAutosaveName] = chevronPos
        lastKnownChevronPos = chevronPos

        let dividerPos = chevronPos + 0.01
        StatusItemDefaults[.preferredPosition, Self.dividerAutosaveName] = dividerPos
        UserDefaults.standard.synchronize()

        let chevron = NSStatusBar.system.statusItem(withLength: Self.chevronLength)
        chevron.autosaveName = Self.chevronAutosaveName
        chevron.behavior = []
        chevron.isVisible = true
        chevron.button?.image = Self.chevron(collapsed: isCollapsed)
        chevron.button?.imagePosition = .imageOnly
        chevron.button?.target = self
        chevron.button?.action = #selector(chevronClicked)
        chevron.button?.sendAction(on: [.leftMouseDown, .rightMouseUp])
        chevron.button?.toolTip = isCollapsed
            ? String(localized: "Show hidden menu bar items")
            : String(localized: "Hide menu bar items")
        chevronItem = chevron

        let expander = NSStatusBar.system.statusItem(withLength: 0)
        expander.autosaveName = Self.dividerAutosaveName
        expander.behavior = []
        expander.isVisible = true
        expander.button?.image = nil
        expander.button?.window?.ignoresMouseEvents = true
        expanderItem = expander
        cacheExpanderWidthConstraint()

        isActive = true
        applyLengths()
        syncAlwaysHiddenDivider()
        syncHoverTracking()
    }

    private func deactivate() {
        cancelAutoHide()
        removeHoverTracking()
        for item in [chevronItem, expanderItem, alwaysHiddenDivider].compactMap({ $0 }) {
            StatusItemDefaults.removeStatusItemPreservingPosition(item)
        }
        chevronItem = nil
        expanderItem = nil
        expanderWidthConstraint = nil
        alwaysHiddenDivider = nil
        lastKnownChevronPos = nil
        isActive = false
    }

    private func syncAlwaysHiddenDivider() {
        guard isActive else { return }

        if Defaults[.menuBarAlwaysHiddenSection] {
            guard alwaysHiddenDivider == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: Self.collapsedLength)
            item.autosaveName = "AnchorMenuBarAlwaysHiddenDivider"
            item.behavior = []
            item.isVisible = true
            item.button?.image = nil
            item.button?.window?.ignoresMouseEvents = true
            item.button?.toolTip = String(
                localized: "Items to the left of this are always hidden")
            alwaysHiddenDivider = item
        } else if let existing = alwaysHiddenDivider {
            StatusItemDefaults.removeStatusItemPreservingPosition(existing)
            alwaysHiddenDivider = nil
        }
    }

    // MARK: - Expander Alignment

    /// Keeps the expander item immediately to the left of the chevron item.
    ///
    /// In AppKit's right-to-left menu bar layout, a higher preferred position
    /// number places an item further to the left. By placing the expander at
    /// `chevronPos + 0.01`, the expander is guaranteed to sit immediately to
    /// the left of the chevron, pushing everything left of the chevron while
    /// leaving the chevron untouched.
    ///
    /// This is invoked when the chevron is clicked or toggled, safely updating
    /// the divider position if the user ⌘-dragged the chevron to a new location.
    func syncExpanderPositionIfChevronMoved() {
        guard isActive else { return }

        let currentChevronPos = StatusItemDefaults[.preferredPosition, Self.chevronAutosaveName] ?? 1
        let last = lastKnownChevronPos ?? currentChevronPos
        let chevronShifted = abs(currentChevronPos - last) >= 0.001

        guard expanderItem == nil || chevronShifted else { return }

        lastKnownChevronPos = currentChevronPos
        let targetDividerPos = currentChevronPos + 0.01
        realignExpander(to: targetDividerPos)
    }

    private func realignExpander(to targetPos: CGFloat) {
        if let existing = expanderItem {
            expanderWidthConstraint = nil
            NSStatusBar.system.removeStatusItem(existing)
            expanderItem = nil
        }

        StatusItemDefaults[.preferredPosition, Self.dividerAutosaveName] = targetPos
        UserDefaults.standard.synchronize()

        let expander = NSStatusBar.system.statusItem(withLength: 0)
        expander.autosaveName = Self.dividerAutosaveName
        expander.behavior = []
        expander.isVisible = true
        expander.button?.image = nil
        expander.button?.window?.ignoresMouseEvents = true
        expanderItem = expander
        cacheExpanderWidthConstraint()

        applyLengths()
    }

    // MARK: - Hover

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
        guard !NSEvent.modifierFlags.contains(.command) else { return }
        toggle()
    }

    func toggle() {
        guard isActive else { return }
        syncExpanderPositionIfChevronMoved()
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

    private func cacheExpanderWidthConstraint() {
        guard let button = expanderItem?.button,
              let contentView = button.window?.contentView
        else { return }

        let constraints = contentView.constraintsAffectingLayout(for: .horizontal)
        expanderWidthConstraint = constraints.first(where: { $0.secondItem === button.superview })
    }

    private func applyLengths() {
        // The chevron always maintains standard length so it is ALWAYS visible.
        chevronItem?.button?.image = Self.chevron(collapsed: isCollapsed)
        chevronItem?.button?.toolTip = isCollapsed
            ? String(localized: "Show hidden menu bar items")
            : String(localized: "Hide menu bar items")

        // Ensure expander exists if active
        if expanderItem == nil && isActive {
            let targetPos = (lastKnownChevronPos ?? 1) + 0.01
            realignExpander(to: targetPos)
            return
        }

        guard let expander = expanderItem, isActive else { return }

        if expanderWidthConstraint == nil {
            cacheExpanderWidthConstraint()
        }

        // Ice logic: Keep isVisible = true permanently.
        // Toggling length between 10_000 and 0 triggers AppKit's native, hardware-accelerated
        // sliding animation without window teardown or scene-fence stalls.
        if isCollapsed {
            expander.length = Self.collapsedLength
            expanderWidthConstraint?.isActive = true
            if let button = expander.button {
                button.cell?.isEnabled = false
                button.isHighlighted = false
                button.image = nil
                button.window?.ignoresMouseEvents = true
            }
        } else {
            expander.length = 0
            expanderWidthConstraint?.isActive = false
            if let window = expander.button?.window {
                var size = window.frame.size
                size.width = 1
                window.setContentSize(size)
            }
            if let button = expander.button {
                button.cell?.isEnabled = true
            }
        }

        alwaysHiddenDivider?.length = Self.collapsedLength
    }

    // MARK: - Auto-hide

    /// Re-hides the section after the user leaves the menu bar, matching Ice's rehide strategy.
    private func scheduleAutoHide() {
        cancelAutoHide()
        let seconds = Defaults[.menuBarAutoHideSeconds]
        guard seconds > 0 else { return }

        rehideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            guard let self, !self.isCollapsed else { return }
            let mouseLoc = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouseLoc) } ?? NSScreen.main
            guard let screen else { return }

            if mouseLoc.y < screen.visibleFrame.maxY {
                if self.rehideTimer == nil {
                    self.armRehideTimer(seconds: seconds, screen: screen)
                }
            } else {
                self.rehideTimer?.cancel()
                self.rehideTimer = nil
            }
        }

        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLoc) } ?? NSScreen.main
        if let screen, mouseLoc.y < screen.visibleFrame.maxY {
            armRehideTimer(seconds: seconds, screen: screen)
        }
    }

    private func armRehideTimer(seconds: Int, screen: NSScreen) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Double(seconds), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isCollapsed else { return }
            let mouseLoc = NSEvent.mouseLocation
            if mouseLoc.y < screen.visibleFrame.maxY {
                self.collapse()
            } else {
                self.rehideTimer = nil
                self.scheduleAutoHide()
            }
        }
        rehideTimer = timer
        timer.resume()
    }

    private func cancelAutoHide() {
        if let monitor = rehideMonitor {
            NSEvent.removeMonitor(monitor)
            rehideMonitor = nil
        }
        rehideTimer?.cancel()
        rehideTimer = nil
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
