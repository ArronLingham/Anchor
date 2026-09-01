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

    /// 1-based, matching how Mission Control labels desktops. Zero when the
    /// number cannot be determined.
    @Published private(set) var currentSpace = 0
    @Published private(set) var totalSpaces = 0

    private var observer: Any?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Defaults.publisher(.showSpaceIndicator)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.syncToSettings() }
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
        currentSpace = 0
        totalSpaces = 0
    }

    /// Walks the managed display list, counting user spaces and finding where
    /// the current one sits.
    private func refresh() {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]]
        else { return }

        var index = 0
        var total = 0
        var found = 0

        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let currentID = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int

            for space in spaces {
                // Fullscreen apps occupy their own space and are not desktops;
                // counting them makes the number jump when you fullscreen
                // something, which is not what anyone means by "desktop 3".
                let type = space["type"] as? Int ?? 0
                guard type == 0 else { continue }
                total += 1
                if let id = space["ManagedSpaceID"] as? Int, id == currentID {
                    index = total
                }
            }
            if index != 0 && found == 0 { found = index }
        }

        if currentSpace != index { currentSpace = index }
        if totalSpaces != total { totalSpaces = total }
    }
}
