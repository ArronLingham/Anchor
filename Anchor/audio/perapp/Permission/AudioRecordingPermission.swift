/*
 * Anchor
 * Per-app audio engine, derived from FineTune (github.com/ronitsingh10/FineTune).
 * Copyright (C) 2026 Ronit Singh
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
import AppKit
import os

private let logger = os.Logger(subsystem: "com.arronlingham.Anchor", category: "Permission")

// MARK: - Permission Status

enum AudioCapturePermissionStatus {
    case unknown
    case authorized
    case denied
}

// MARK: - AudioRecordingPermission

@Observable
@MainActor
final class AudioRecordingPermission {

    var status: AudioCapturePermissionStatus = .unknown

    init() {
        refreshStatus()
        registerForActivation()
    }

    /// Check current TCC status without prompting.
    func refreshStatus() {
        #if ENABLE_TCC_SPI
        let result = Self.preflight()
        switch result {
        case 0:
            status = .authorized
        case 1:
            status = .denied
        default:
            status = .unknown
        }
        logger.debug("Audio capture permission preflight: \(result) → \(String(describing: self.status))")
        #else
        status = .authorized
        #endif
    }

    /// Trigger the system permission dialog. Only shows once per app per TCC service.
    /// Subsequent calls are no-ops at the OS level.
    func request() {
        #if ENABLE_TCC_SPI
        guard status != .authorized else { return }
        Self.requestAccess { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.status = granted ? .authorized : .denied
                logger.info("Audio capture permission request result: \(granted)")
            }
        }
        #endif
    }

    // MARK: - App Activation Observer

    private func registerForActivation() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatus()
            }
        }
    }

    // MARK: - TCC SPI (Private Framework)

    #if ENABLE_TCC_SPI
    private static let tccServiceAudioCapture = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let apiHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }()

    private static let preflightSPI: PreflightFunc? = {
        guard let handle = apiHandle,
              let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFunc.self)
    }()

    private static let requestSPI: RequestFunc? = {
        guard let handle = apiHandle,
              let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFunc.self)
    }()

    /// Returns: 0 = authorized, 1 = denied, -1 = SPI unavailable
    private static func preflight() -> Int {
        guard let spi = preflightSPI else {
            logger.warning("TCC preflight SPI unavailable")
            return -1
        }
        return spi(tccServiceAudioCapture, nil)
    }

    private static func requestAccess(completion: @escaping (Bool) -> Void) {
        guard let spi = requestSPI else {
            logger.warning("TCC request SPI unavailable")
            completion(false)
            return
        }
        spi(tccServiceAudioCapture, nil, completion)
    }
    #endif
}
