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
import AppKit
import Combine
import Defaults
import Foundation

/// A live camera preview in the notch.
///
/// ## The camera runs only while the preview is on screen
///
/// This is the whole design constraint. A capture session left running holds
/// the camera open, keeps the green indicator lit and costs real CPU, so the
/// session is built on `start()` and **torn down** on `stop()` — not paused,
/// not left idle. `AudioTap` is the precedent in this codebase and this
/// follows it: nothing exists while the feature is off.
///
/// ## Nothing is recorded
///
/// There is no `AVCaptureMovieFileOutput`, no photo output and no buffer
/// delegate. The session's only output is an `AVCaptureVideoPreviewLayer`,
/// which draws frames and keeps none. That is a deliberate structural choice
/// rather than a promise: there is no code path that could write a frame
/// anywhere, so the usage string's claim is enforced by the shape of the class.
@MainActor
final class CameraMirrorManager: NSObject, ObservableObject {
    static let shared = CameraMirrorManager()

    /// Whether the preview is currently showing.
    @Published private(set) var isRunning = false
    /// Set when the camera cannot be used, for the UI to explain rather than
    /// showing an empty black rectangle.
    @Published private(set) var failure: String?
    @Published private(set) var availableCameras: [AVCaptureDevice] = []

    /// The layer a SwiftUI view hosts. Nil while stopped.
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    private var session: AVCaptureSession?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private override init() { super.init() }

    func start() {
        guard !started else { return }
        started = true

        Defaults.publisher(.enableCameraMirror)
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
            .store(in: &cancellables)

        Defaults.publisher(.cameraMirrorDeviceID)
            .sink { [weak self] _ in
                Task { @MainActor in
                    // Rebuild rather than swap inputs: switching a device on a
                    // running session needs begin/commitConfiguration and
                    // fails silently if the new device is gone.
                    guard self?.isRunning == true else { return }
                    self?.stopSession()
                    self?.startSession()
                }
            }
            .store(in: &cancellables)
    }

    private func sync() {
        Defaults[.enableCameraMirror] ? () : stopSession()
    }

    /// The cameras attached right now.
    ///
    /// Enumerating devices does **not** open the camera and does not trigger a
    /// permission prompt, so this is safe to call to populate a settings
    /// picker before the user has granted anything.
    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        availableCameras = discovery.devices
    }

    // MARK: Session lifecycle

    /// Builds and starts the capture session.
    ///
    /// Called when the preview appears, never at launch.
    func startSession() {
        guard !isRunning else { return }
        failure = nil

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            buildSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    granted ? self.buildSession()
                            : (self.failure = "Camera access was declined.")
                }
            }
        case .denied, .restricted:
            failure = "Camera access is off for Anchor. Turn it on in System Settings › Privacy & Security › Camera."
        @unknown default:
            failure = "Camera access is unavailable."
        }
    }

    private func buildSession() {
        refreshDevices()
        let preferred = Defaults[.cameraMirrorDeviceID]
        let device = availableCameras.first { $0.uniqueID == preferred }
            ?? availableCameras.first

        guard let device else {
            failure = "No camera found."
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            failure = "Could not open \(device.localizedName)."
            return
        }

        let session = AVCaptureSession()
        // .medium rather than .high: this is a small preview in a notch, and a
        // 4K Continuity Camera feed costs real CPU to scale down for it.
        session.sessionPreset = .medium
        guard session.canAddInput(input) else {
            failure = "Could not use \(device.localizedName)."
            return
        }
        session.addInput(input)

        // The ONLY output is a preview layer. No file output, no photo output,
        // no sample-buffer delegate — so there is no path by which a frame
        // could be written anywhere.
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill

        self.session = session
        self.previewLayer = layer

        // startRunning blocks; off the main thread or the notch stutters when
        // the mirror opens.
        Task.detached(priority: .userInitiated) {
            session.startRunning()
            await MainActor.run { self.isRunning = true }
        }
    }

    /// Tears the session down completely.
    func stopSession() {
        guard let session else {
            isRunning = false
            return
        }
        self.session = nil
        self.previewLayer = nil
        isRunning = false
        Task.detached(priority: .utility) { session.stopRunning() }
    }
}
