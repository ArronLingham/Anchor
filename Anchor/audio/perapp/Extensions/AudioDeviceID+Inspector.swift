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
import Foundation
import os

private let logger = os.Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.arronlingham.Anchor",
    category: "AudioDeviceID+Inspector"
)

// MARK: - Inspector Errors

extension AudioDeviceID {
    enum InspectorError: Error {
        case writeFailed(OSStatus)
    }
}

// MARK: - Physical Format

extension AudioDeviceID {
    /// Reads the physical format (ASBD) of the device's first output stream.
    /// Returns nil on Bluetooth since the format is negotiated below the HAL layer.
    func readPhysicalFormat(
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> AudioStreamBasicDescription? {
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let sizeErr = AudioObjectGetPropertyDataSize(self, &streamsAddress, 0, nil, &size)
        guard sizeErr == noErr, size >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return nil
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var streams = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let streamsErr = AudioObjectGetPropertyData(self, &streamsAddress, 0, nil, &size, &streams)
        guard streamsErr == noErr,
              let firstStream = streams.first,
              firstStream != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatErr = AudioObjectGetPropertyData(firstStream, &formatAddress, 0, nil, &asbdSize, &asbd)
        guard formatErr == noErr else {
            return nil
        }
        return asbd
    }
}

// MARK: - Available Sample Rates

extension AudioDeviceID {
    /// Reads available nominal sample rates. Discrete devices report
    /// `mMinimum == mMaximum` per range; continuous-range pro-audio devices
    /// emit `[min, max]` rather than an enumerated continuum.
    func readAvailableSampleRates(
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let sizeErr = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard sizeErr == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        let dataErr = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &ranges)
        guard dataErr == noErr else {
            return []
        }

        var rates: [Double] = []
        rates.reserveCapacity(count)
        for range in ranges {
            if range.mMinimum == range.mMaximum {
                rates.append(range.mMinimum)
            } else {
                rates.append(range.mMinimum)
                rates.append(range.mMaximum)
            }
        }
        return rates
    }
}

// MARK: - Hog Mode

extension AudioDeviceID {
    /// Reads the hog-mode owner PID, or -1 when nobody holds it. Callers
    /// should compare against `getpid()` to suppress self-owned hog mode.
    func readHogModeOwner() -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var owner: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &owner)
        guard err == noErr else {
            return -1
        }
        return owner
    }
}

// MARK: - Nominal Sample Rate Write

extension AudioDeviceID {
    /// Writes a new nominal sample rate. Throws `InspectorError.writeFailed`
    /// when the device refuses the change. Callers should gate this via
    /// `isPropertySettable` first. Global scope: the property is device-wide,
    /// and output-scope writes silently no-op on some drivers.
    func writeNominalSampleRate(
        _ rate: Double,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var value = Float64(rate)
        let size = UInt32(MemoryLayout<Float64>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &value)
        guard err == noErr else {
            logger.debug("writeNominalSampleRate(\(rate)) failed with OSStatus \(err)")
            throw InspectorError.writeFailed(err)
        }
    }
}

// MARK: - Settability

extension AudioDeviceID {
    /// Wraps `AudioObjectIsPropertySettable`. Returns `false` on call failure
    /// so the UI never shows a picker that would silently no-op.
    func isPropertySettable(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(self, &address) else { return false }

        var settable: DarwinBoolean = false
        let err = AudioObjectIsPropertySettable(self, &address, &settable)
        return err == noErr && settable.boolValue
    }
}
