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

/// Monitors screen corners and triggers the launcher when cursor enters the configured hot corner.
@MainActor
final class LauncherHotCornerMonitor {
    static let shared = LauncherHotCornerMonitor()

    private let edgeThreshold: CGFloat = 26
    private let activationCooldown: TimeInterval = 1.0

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenChangeObserver: NSObjectProtocol?
    private var subscriptions = Set<AnyCancellable>()
    private var generation = UUID()
    private var lastTriggerDate: Date?
    private var isEvalPending = false
    private var cachedCornerRects: [CGRect] = []

    private init() {}

    func setup() {
        guard subscriptions.isEmpty else { return }
        Defaults.publisher(.enableLauncher, options: [])
            .sink { [weak self] _ in self?.preferenceChanged() }
            .store(in: &subscriptions)
        Defaults.publisher(.launcherHotCorner, options: [])
            .sink { [weak self] _ in self?.preferenceChanged() }
            .store(in: &subscriptions)
        sync()
    }

    nonisolated private func preferenceChanged() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { reconcilePreferenceChange() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.reconcilePreferenceChange() }
        }
    }

    private func reconcilePreferenceChange() {
        guard !subscriptions.isEmpty else { return }
        stopMonitoring()
        sync()
    }

    func stop() {
        subscriptions.removeAll()
        stopMonitoring()
    }

    private func sync() {
        let corner = Defaults[.launcherHotCorner]
        guard screenChangeObserver == nil, Defaults[.enableLauncher], corner != .none else { return }
        let generation = generation
        updateCachedCornerRects(corner: corner)

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCurrent(generation, corner: corner) else { return }
                self.updateCachedCornerRects(corner: corner)
            }
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleEvaluation(generation: generation, corner: corner) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.scheduleEvaluation(generation: generation, corner: corner)
            return event
        }
    }

    private func stopMonitoring() {
        generation = UUID()
        isEvalPending = false
        if let monitor = globalMouseMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMouseMonitor { NSEvent.removeMonitor(monitor) }
        if let observer = screenChangeObserver { NotificationCenter.default.removeObserver(observer) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        screenChangeObserver = nil
        cachedCornerRects = []
        lastTriggerDate = nil
    }

    private func isCurrent(_ generation: UUID, corner: LauncherHotCorner) -> Bool {
        self.generation == generation && Defaults[.enableLauncher] && Defaults[.launcherHotCorner] == corner
    }

    private func scheduleEvaluation(generation: UUID, corner: LauncherHotCorner) {
        guard !isEvalPending, isCurrent(generation, corner: corner),
              cachedCornerRects.contains(where: { $0.contains(NSEvent.mouseLocation) }) else { return }
        isEvalPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(generation, corner: corner) else { return }
            self.isEvalPending = false
            self.evaluateCursorLocation()
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

    private func evaluateCursorLocation() {
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
