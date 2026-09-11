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
import Defaults

/// Monitors screen corners and triggers the launcher when cursor enters the configured hot corner.
@MainActor
final class LauncherHotCornerMonitor {
    static let shared = LauncherHotCornerMonitor()

    private let edgeThreshold: CGFloat = 26
    private let activationCooldown: TimeInterval = 1.0

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenChangeObserver: NSObjectProtocol?
    private var lastTriggerDate: Date?
    private var isEvalPending = false
    private var cachedCornerRects: [CGRect] = []

    private init() {}

    /// Starts or stops monitoring based on current settings.
    func setup() {
        Defaults.observe(.launcherHotCorner) { [weak self] change in
            self?.update(corner: change.newValue)
        }.tieToLifetime(of: self)

        update(corner: Defaults[.launcherHotCorner])
    }

    func update(corner: LauncherHotCorner) {
        if corner == .none {
            stopMonitoring()
        } else {
            updateCachedCornerRects(corner: corner)
            startMonitoringIfNeeded(corner: corner)
        }
    }

    func stopMonitoring() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            screenChangeObserver = nil
        }
        cachedCornerRects = []
        lastTriggerDate = nil
    }

    private func startMonitoringIfNeeded(corner: LauncherHotCorner) {
        updateCachedCornerRects(corner: corner)

        if screenChangeObserver == nil {
            screenChangeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateCachedCornerRects(corner: Defaults[.launcherHotCorner])
                }
            }
        }

        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                guard let self, !self.isEvalPending else { return }
                let location = NSEvent.mouseLocation
                let rects = self.cachedCornerRects
                guard rects.contains(where: { $0.contains(location) }) else { return }
                self.isEvalPending = true
                DispatchQueue.main.async { [weak self] in
                    self?.isEvalPending = false
                    self?.evaluateCursorLocation(corner: Defaults[.launcherHotCorner])
                }
            }
        }

        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                if let self, !self.isEvalPending {
                    let location = NSEvent.mouseLocation
                    let rects = self.cachedCornerRects
                    if rects.contains(where: { $0.contains(location) }) {
                        self.isEvalPending = true
                        DispatchQueue.main.async { [weak self] in
                            self?.isEvalPending = false
                            self?.evaluateCursorLocation(corner: Defaults[.launcherHotCorner])
                        }
                    }
                }
                return event
            }
        }
    }

    private func updateCachedCornerRects(corner: LauncherHotCorner) {
        guard corner != .none else {
            cachedCornerRects = []
            return
        }

        let threshold = edgeThreshold
        cachedCornerRects = NSScreen.screens.map { screen in
            let frame = screen.frame
            let x: CGFloat
            let y: CGFloat
            switch corner {
            case .topLeft, .bottomLeft:
                x = frame.minX
            case .topRight, .bottomRight:
                x = frame.maxX - threshold
            case .none:
                x = 0
            }
            switch corner {
            case .topLeft, .topRight:
                y = frame.maxY - threshold
            case .bottomLeft, .bottomRight:
                y = frame.minY
            case .none:
                y = 0
            }
            return CGRect(x: x, y: y, width: threshold, height: threshold)
        }
    }

    private func evaluateCursorLocation(corner: LauncherHotCorner) {
        guard corner != .none else { return }
        let currentLocation = NSEvent.mouseLocation

        let now = Date()
        if let last = lastTriggerDate, now.timeIntervalSince(last) < activationCooldown {
            return
        }

        guard cachedCornerRects.contains(where: { $0.contains(currentLocation) }) else {
            return
        }

        lastTriggerDate = now
        LauncherPanelManager.shared.show()
    }
}
