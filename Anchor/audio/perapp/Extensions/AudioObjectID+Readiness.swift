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

import AudioToolbox
import CoreFoundation

// MARK: - Device Readiness

extension AudioObjectID {
    /// Check if an audio device is currently alive and operational.
    /// Uses kAudioDevicePropertyDeviceIsAlive to verify device state.
    /// - Returns: `true` if device is alive, `false` if dead or query fails.
    func isDeviceAlive() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &isAlive)
        return status == noErr && isAlive != 0
    }

    /// Wait for an audio device to become ready, processing HAL events via CFRunLoop.
    /// - Parameters:
    ///   - timeout: Maximum time to wait in seconds (default: 1.0)
    ///   - pollInterval: Time between readiness checks in seconds (default: 0.01)
    /// - Returns: `true` if device became ready within timeout, `false` otherwise.
    /// - Warning: This method blocks the calling thread via CFRunLoopRunInMode. Do not call from the main thread without careful consideration.
    /// - Note: Uses CFRunLoopRunInMode to allow Core Audio HAL events to be processed
    ///         during the wait. This is critical for aggregate device initialization.
    func waitUntilReady(timeout: TimeInterval = 1.0, pollInterval: TimeInterval = 0.01) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout

        while CFAbsoluteTimeGetCurrent() < deadline {
            if isDeviceAlive() {
                return true
            }
            // Process HAL events while waiting - critical for aggregate device stabilization
            CFRunLoopRunInMode(.defaultMode, pollInterval, false)
        }

        return false
    }
}
