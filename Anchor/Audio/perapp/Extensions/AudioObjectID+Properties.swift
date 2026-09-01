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

// MARK: - AudioObjectID Core Extensions

nonisolated extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    static let system = AudioObjectID(kAudioObjectSystemObject)

    var isValid: Bool { self != Self.unknown }
}

// MARK: - Property Reading

nonisolated extension AudioObjectID {
    func read<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioScope = .global,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope.propertyScope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return value
    }

    func readBool(_ selector: AudioObjectPropertySelector, scope: AudioScope = .global) throws -> Bool {
        let value: UInt32 = try read(selector, scope: scope, defaultValue: 0)
        return value != 0
    }

    func readString(_ selector: AudioObjectPropertySelector, scope: AudioScope = .global) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope.propertyScope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }

        // CFString-returning selectors transfer +1 ownership per AudioHardwareBase.h
        // ("The caller is responsible for releasing the returned CFObject"). Reading
        // into an Unmanaged slot keeps that retain explicit; takeRetainedValue consumes it.
        var unmanaged: Unmanaged<CFString>? = nil
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        err = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        guard err == noErr, let unmanaged else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return unmanaged.takeRetainedValue() as String
    }

    func readStringWithQualifier(
        _ selector: AudioObjectPropertySelector,
        scope: AudioScope = .output,
        qualifier: UInt32
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope.propertyScope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(self, &address) else { return nil }

        // Get actual data size — some HAL plugins write more than MemoryLayout<CFString>.size,
        // corrupting the stack if we use a stack-allocated buffer.
        var qual = qualifier
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(
            self, &address,
            UInt32(MemoryLayout<UInt32>.size), &qual,
            &dataSize
        )
        guard err == noErr, dataSize > 0 else { return nil }

        // Heap-allocate to avoid stack buffer overflow from buggy drivers
        let capacity = Swift.max(1, Int(dataSize) / MemoryLayout<CFString>.size)
        let buffer = UnsafeMutablePointer<CFString>.allocate(capacity: capacity)
        defer { buffer.deinitialize(count: 1); buffer.deallocate() }
        buffer.initialize(to: "" as CFString)

        err = AudioObjectGetPropertyData(
            self, &address,
            UInt32(MemoryLayout<UInt32>.size), &qual,
            &dataSize, buffer
        )
        guard err == noErr else { return nil }
        return buffer.pointee as String
    }
}

// MARK: - Array Property Reading

nonisolated extension AudioObjectID {
    func readArray<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioScope = .global,
        defaultValue: T
    ) throws -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope.propertyScope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }

        let count = Int(size) / MemoryLayout<T>.size
        var items = [T](repeating: defaultValue, count: count)
        err = items.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        return items
    }
}
