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
import Darwin
import AppKit
import Defaults
import SwiftUI

// Both private entry points must be available so a registration can be removed.
private typealias ScreenCaptureCallback = @convention(c) (Int32, UnsafeRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
private typealias ScreenCaptureRegistration = @convention(c) (ScreenCaptureCallback, Int32, UnsafeMutableRawPointer?) -> Int32

@_silgen_name("CGSIsScreenWatcherPresent")
private func CGSIsScreenWatcherPresent() -> Bool

private enum ScreenCaptureNotifications {
    static let backend: ScreenRecordingManager.Notifications? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else {
            return nil
        }
        guard let add = dlsym(handle, "CGSRegisterNotifyProc"),
              let remove = dlsym(handle, "CGSRemoveNotifyProc") else {
            dlclose(handle)
            return nil
        }
        let register = unsafeBitCast(add, to: ScreenCaptureRegistration.self)
        let unregister = unsafeBitCast(remove, to: ScreenCaptureRegistration.self)
        return .init(
            add: { register(screenCaptureEventCallback, $0, UnsafeMutableRawPointer(bitPattern: $1)) },
            remove: { unregister(screenCaptureEventCallback, $0, UnsafeMutableRawPointer(bitPattern: $1)) }
        )
    }()
}

private func screenCaptureEventCallback(
    event: Int32, _: UnsafeRawPointer?, _: UInt32, context: UnsafeMutableRawPointer?
) {
    // The context is an opaque generation number. It never points to Swift memory.
    guard let context else { return }
    let generation = UInt(bitPattern: context)
    DispatchQueue.main.async {
        ScreenRecordingManager.shared.handleCaptureEvent(generation: generation)
    }
}

@MainActor
class ScreenRecordingManager: ObservableObject {
    struct Notifications {
        var add: (Int32, UInt) -> Int32
        var remove: (Int32, UInt) -> Int32
    }

    static let shared = ScreenRecordingManager(
        notifications: ScreenCaptureNotifications.backend,
        isEnabled: { Defaults[.enableScreenRecordingDetection] && !AppRuntimeEnvironment.isUITesting },
        isBeingRecorded: CGSIsScreenWatcherPresent
    )

    private let coordinator = AnchorViewCoordinator.shared
    private let notifications: Notifications?
    private let isEnabled: () -> Bool
    private let isBeingRecorded: () -> Bool
    private var generation: UInt = 0
    private var registrations: [Int32: UInt] = [:]
    
    // MARK: - Published Properties
    @Published var isRecording: Bool = false
    @Published private(set) var isMonitoring: Bool = false
    /// Derived on demand: a duration read must not invalidate every notch view.
    var recordingDuration: TimeInterval {
        recordingStartTime.map { Date().timeIntervalSince($0) } ?? lastRecordingDuration
    }
    @Published var isRecorderIdle: Bool = true
    @Published var lastUpdated: Date = .distantPast
    
    // MARK: - Private Properties
    private var recordingStartTime: Date?
    private var lastRecordingDuration: TimeInterval = 0
    private var debounceIdleTask: Task<Void, Never>?
    private var durationResetTask: Task<Void, Never>?
    
    init(notifications: Notifications?, isEnabled: @escaping () -> Bool, isBeingRecorded: @escaping () -> Bool) {
        self.notifications = notifications
        self.isEnabled = isEnabled
        self.isBeingRecorded = isBeingRecorded
    }

    deinit {
        debounceIdleTask?.cancel()
        durationResetTask?.cancel()
    }

    func startMonitoring() {
        guard !isMonitoring, isEnabled(), let notifications else { return }
        removeCaptureNotifications()
        generation += 1
        for event: Int32 in [1502, 1503] where registrations[event] == nil {
            let status = notifications.add(event, generation)
            if status == 0 {
                registrations[event] = generation
            } else {
                NSLog("Screen recording detection: could not register event \(event) (\(status))")
            }
        }
        guard registrations.values.contains(generation) else { return }
        isMonitoring = true
        checkRecordingStatus()
    }

    func stopMonitoring() {
        isMonitoring = false
        removeCaptureNotifications()
        debounceIdleTask?.cancel()
        debounceIdleTask = nil
        durationResetTask?.cancel()
        durationResetTask = nil
        recordingStartTime = nil
        lastRecordingDuration = 0
        isRecorderIdle = true
        isRecording = false
        if coordinator.expandingView.type == .recording, coordinator.expandingView.show {
            withAnimation(.smooth) { coordinator.expandingView.show = false }
        }
    }

    private func removeCaptureNotifications() {
        guard let notifications else { return }
        for (event, generation) in registrations {
            let status = notifications.remove(event, generation)
            if status == 0 {
                registrations.removeValue(forKey: event)
            } else {
                NSLog("Screen recording detection: could not remove event \(event) (\(status))")
            }
        }
    }

    fileprivate func handleCaptureEvent(generation: UInt) {
        guard generation == self.generation else { return }
        checkRecordingStatus()
    }

    private func checkRecordingStatus() {
        guard isMonitoring, isEnabled() else { return }
        let recording = isBeingRecorded()
        guard recording != isRecording else { return }
        lastUpdated = Date()
        if recording {
            startDurationTracking()
            // Main-actor publication is synchronous, so an old notification
            // cannot queue an expansion that appears after disablement.
            withAnimation(.smooth) {
                coordinator.expandingView = .init(show: true, type: .recording)
            }
        } else {
            stopDurationTracking()
        }
        updateIdleState(recording: recording)
        withAnimation(.smooth) { isRecording = recording }
    }

    /// Keep timestamps without scheduling updates for a readout that is not visible.
    private func startDurationTracking() {
        durationResetTask?.cancel()
        durationResetTask = nil
        recordingStartTime = Date()
        lastRecordingDuration = 0
    }

    private func stopDurationTracking() {
        lastRecordingDuration = recordingDuration
        recordingStartTime = nil

        durationResetTask?.cancel()
        durationResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.lastRecordingDuration = 0
            self.durationResetTask = nil
        }
    }

    /// Briefly hold the recording live activity after capture ends.
    private func updateIdleState(recording: Bool) {
        if recording {
            isRecorderIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                guard let self = self, !Task.isCancelled else { return }
                await MainActor.run {
                    if self.lastUpdated.timeIntervalSinceNow < -Defaults[.waitInterval] {
                        withAnimation {
                            self.isRecorderIdle = !self.isRecording
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Extensions

extension ScreenRecordingManager {
    /// Get formatted recording duration string
    var formattedDuration: String {
        let totalSeconds = Int(recordingDuration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}