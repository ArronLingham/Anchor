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

import AVFoundation
import Combine
import Defaults
import Foundation

/// Camera mirror — a look-at-yourself view in the notch.
///
/// **Not reachable yet, and deliberately so.** There is no Settings toggle for
/// `enableCameraMirror`, so `NotchCameraMirrorView` is never built and this
/// manager never starts. Adding that toggle was refused as a change needing
/// explicit human authorization, which a camera feature reasonably does.
///
/// Kept rather than deleted for the same reason as `utils/SMC.swift`: it is
/// complete and correct, and going live is a single `Defaults.Toggle` in
/// `SettingsGeneral` plus a case wherever the notch should show it. No
/// entitlement or build-setting change is needed — see the note below.
///
/// **Reference-counted, exactly like `AudioTap`.** A capture session keeps the
/// camera powered, the privacy light lit and a real-time thread running, so it
/// exists only while something is actually drawing it: views `acquire()` on
/// appear and `release()` on disappear, and the session is built on 0 → 1 and
/// torn down on 1 → 0. Starting it at launch would be the most expensive thing
/// in this app by a wide margin.
///
/// Access is governed entirely by TCC — macOS prompts on first use and lights
/// the green indicator whenever the session runs. Nothing here weakens that,
/// and no entitlement is involved: this app is not sandboxed, so
/// `com.apple.security.device.camera` would be inert.
@MainActor
final class CameraMirrorManager: ObservableObject {
    static let shared = CameraMirrorManager()

    enum State: Equatable {
        case idle
        case denied
        case unavailable
        case running
    }

    @Published private(set) var state: State = .idle

    /// Handed to the view layer to draw. Nil unless running.
    private(set) var session: AVCaptureSession?

    private var consumerCount = 0
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Never block in a manager's init — see CLAUDE.md.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Switching the feature off must drop a running session now, not
            // whenever the view happens to disappear.
            Defaults.publisher(.enableCameraMirror)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] change in
                    guard let self else { return }
                    if change.newValue {
                        if self.consumerCount > 0 { self.startIfNeeded() }
                    } else {
                        self.teardown()
                    }
                }
                .store(in: &self.cancellables)
        }
    }

    /// Call from `onAppear`. Balanced by `release()`.
    func acquire() {
        consumerCount += 1
        if consumerCount == 1 { startIfNeeded() }
    }

    /// Call from `onDisappear`.
    func release() {
        consumerCount = max(0, consumerCount - 1)
        if consumerCount == 0 { teardown() }
    }

    private func startIfNeeded() {
        guard Defaults[.enableCameraMirror], session == nil else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            build()
        case .notDetermined:
            Task { @MainActor in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard granted else {
                    self.state = .denied
                    return
                }
                // The user may have navigated away while the prompt was up.
                guard self.consumerCount > 0 else { return }
                self.build()
            }
        default:
            state = .denied
        }
    }

    private func build() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            state = .unavailable
            return
        }

        let session = AVCaptureSession()
        // The notch view is small. A full-resolution feed costs far more to
        // move around than it can possibly show.
        session.sessionPreset = .medium

        guard session.canAddInput(input) else {
            state = .unavailable
            return
        }
        session.addInput(input)

        self.session = session
        state = .running

        // startRunning blocks until the device is configured, so keep it off
        // the main thread.
        Task.detached(priority: .userInitiated) {
            session.startRunning()
        }
    }

    private func teardown() {
        guard let session else { return }
        self.session = nil
        state = .idle
        Task.detached(priority: .utility) {
            session.stopRunning()
        }
    }
}
