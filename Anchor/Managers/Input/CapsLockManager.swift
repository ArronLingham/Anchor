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

import Foundation
import Combine
import AppKit
import Defaults
import SwiftUI

@MainActor
class CapsLockManager: ObservableObject {
    static let shared = CapsLockManager()
    
    @Published private(set) var isCapsLockActive = false
    
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var monitorGeneration = UUID()
    private var preferenceObserver: AnyCancellable?
    private let coordinator = AnchorViewCoordinator.shared
    private let capsLockAnimation = Animation.spring(response: 0.32, dampingFraction: 0.85)
    
    private init() {
        preferenceObserver = Defaults.publisher(.enableCapsLockIndicator, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                if change.newValue { self?.startMonitoring() } else { self?.stopMonitoring() }
            }
        startMonitoring()
    }

    private func startMonitoring() {
        guard Defaults[.enableCapsLockIndicator],
              localEventMonitor == nil, globalEventMonitor == nil else { return }
        let generation = monitorGeneration
        isCapsLockActive = NSEvent.modifierFlags.contains(.capsLock)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event.modifierFlags.contains(.capsLock), generation: generation)
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let active = event.modifierFlags.contains(.capsLock)
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(active, generation: generation)
            }
        }
    }

    private func stopMonitoring() {
        monitorGeneration = UUID()
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if isCapsLockActive { isCapsLockActive = false }
        hideIndicator()
    }

    private func handleFlagsChanged(_ active: Bool, generation: UUID) {
        guard Defaults[.enableCapsLockIndicator], generation == monitorGeneration,
              active != isCapsLockActive else { return }
        withAnimation(capsLockAnimation) {
            isCapsLockActive = active
        }
        if active {
            coordinator.toggleSneakPeek(
                status: true,
                type: .capsLock,
                duration: .infinity, // Stay visible until deactivated
                value: 1.0,
                icon: ""
            )
        } else {
            hideIndicator()
        }
    }

    private func hideIndicator() {
        guard coordinator.sneakPeek.show, coordinator.sneakPeek.type == .capsLock else { return }
        coordinator.toggleSneakPeek(status: false, type: .capsLock, duration: 0, value: 0, icon: "")
    }
}
