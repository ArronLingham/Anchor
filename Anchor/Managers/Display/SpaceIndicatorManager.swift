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

// SkyLight's space enumeration. There is no public API that reports which
// desktop you are on — Mission Control's own numbering comes from here.
private typealias CGSConnectionID = UInt
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

/// Which desktop you are on. Category 7.
///
/// Entirely notification-driven: macOS posts `activeSpaceDidChangeNotification`
/// when the desktop changes, so there is nothing to poll and nothing scheduled.
/// The private call below runs once per switch, not on a timer.
@MainActor
final class SpaceIndicatorManager: ObservableObject {
    static let shared = SpaceIndicatorManager()

    /// Where one display sits in its own desktop list.
    struct Position: Equatable {
        /// 1-based, matching how Mission Control labels desktops.
        let index: Int
        let total: Int
    }

    /// Per display, keyed by `NSScreen.localizedName` — the same key
    /// `MusicControlWindowManager` uses, so the two agree about what a display
    /// is. Spaces are per-display whenever "Displays have separate Spaces" is
    /// on, and the notch exists once per screen, so a single global number was
    /// always going to be wrong on one of them.
    @Published private(set) var positions: [String: Position] = [:]

    /// The main screen's position, kept for callers that have no screen to
    /// offer. 1-based; zero when the number cannot be determined.
    @Published private(set) var currentSpace = 0
    @Published private(set) var totalSpaces = 0

    /// The desktop number for `screenName`, falling back to the main screen.
    func position(for screenName: String?) -> Position? {
        if let screenName, let p = positions[screenName] { return p }
        if let main = NSScreen.main?.localizedName { return positions[main] }
        return nil
    }

    /// The CFUUID string CGS uses in `Display Identifier`, for one screen.
    private static func displayIdentifier(for screen: NSScreen) -> String? {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?
                .takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private var observer: Any?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Defaults.publisher(.showSpaceIndicator)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.syncToSettings() }
                .store(in: &self.cancellables)
            // Without this the fullscreen setting would be a dead switch: the
            // count is only ever recomputed on a Space change, so flipping it
            // would appear to do nothing until the user switched desktop.
            Defaults.publisher(.countFullscreenSpaces)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, Defaults[.showSpaceIndicator] else { return }
                    self.refresh()
                }
                .store(in: &self.cancellables)
            self.syncToSettings()
        }
    }

    private func syncToSettings() {
        if Defaults[.showSpaceIndicator] { start() } else { stop() }
    }

    private func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    private func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        positions = [:]
        currentSpace = 0
        totalSpaces = 0
    }

    /// Walks the managed display list, recording where each display sits in
    /// its own desktop list.
    ///
    /// Three things here were wrong and are worth not re-deriving:
    ///  - `total` accumulated across *every* display instead of resetting per
    ///    display, so with two monitors both the index and the count came from
    ///    a flattened cross-display list.
    ///  - The target display came from `NSScreen.main`, which is the *focused*
    ///    screen, not the screen whose notch is asking.
    ///  - A fullscreen app occupies its own space with a non-zero `type`, so
    ///    when the active space was fullscreen nothing matched and the badge
    ///    vanished entirely rather than holding its last value.
    private func refresh() {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]]
        else { return }

        let countFullscreen = Defaults[.countFullscreenSpaces]

        var nameByIdentifier: [String: String] = [:]
        for screen in NSScreen.screens {
            if let id = Self.displayIdentifier(for: screen) {
                nameByIdentifier[id] = screen.localizedName
            }
        }

        var next: [String: Position] = [:]
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let currentID = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int

            var index = 0
            var total = 0
            for space in spaces {
                let type = space["type"] as? Int ?? 0
                // type 0 is a user desktop. Fullscreen apps each get their own
                // space, so counting them makes the number jump the moment you
                // fullscreen something — which is not what anyone means by
                // "desktop 3". Hence opt-in rather than default.
                guard type == 0 || countFullscreen else { continue }
                total += 1
                if let id = space["ManagedSpaceID"] as? Int, id == currentID { index = total }
            }

            // CGS reports the main display as the literal string "Main" in some
            // configurations rather than a UUID.
            let identifier = display["Display Identifier"] as? String
            let name = identifier.flatMap { nameByIdentifier[$0] }
                ?? (identifier == "Main" ? NSScreen.main?.localizedName : nil)
            guard let name else { continue }
            next[name] = Position(index: index, total: total)
        }

        if positions != next { positions = next }

        // Bind the name first: `NSScreen.main?.localizedName` is a non-optional
        // String inside an optional chain, so calling .flatMap on it directly
        // picks Collection.flatMap and yields an array of characters' matches.
        let mainName = NSScreen.main?.localizedName
        let main = mainName.flatMap { next[$0] } ?? next.values.first
        if currentSpace != (main?.index ?? 0) { currentSpace = main?.index ?? 0 }
        if totalSpaces != (main?.total ?? 0) { totalSpaces = main?.total ?? 0 }
    }
}
