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

/// Represents how an audio device connects to the system.
/// See kAudioDeviceTransportType* constants in AudioHardware.h
nonisolated enum TransportType: Sendable, Hashable, CustomStringConvertible {
    case builtIn
    case usb
    case bluetooth
    case bluetoothLE
    case airPlay
    case virtual
    case thunderbolt
    case hdmi
    case displayPort
    case aggregate
    case unknown

    init(rawValue: UInt32) {
        switch rawValue {
        case kAudioDeviceTransportTypeBuiltIn:     self = .builtIn
        case kAudioDeviceTransportTypeUSB:         self = .usb
        case kAudioDeviceTransportTypeBluetooth:   self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeAirPlay:     self = .airPlay
        case kAudioDeviceTransportTypeVirtual:     self = .virtual
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeHDMI:        self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAggregate:   self = .aggregate
        default:                                    self = .unknown
        }
    }

    var description: String {
        switch self {
        case .builtIn:     return "builtIn"
        case .usb:         return "usb"
        case .bluetooth:   return "bluetooth"
        case .bluetoothLE: return "bluetoothLE"
        case .airPlay:     return "airPlay"
        case .virtual:     return "virtual"
        case .thunderbolt: return "thunderbolt"
        case .hdmi:        return "hdmi"
        case .displayPort: return "displayPort"
        case .aggregate:   return "aggregate"
        case .unknown:     return "unknown"
        }
    }

    /// Default SF Symbol for this transport type.
    /// Used as fallback when device-specific icon unavailable.
    var defaultIconSymbol: String {
        switch self {
        case .builtIn:     return "hifispeaker"
        case .usb:         return "headphones"
        case .bluetooth:   return "headphones"
        case .bluetoothLE: return "headphones"
        case .airPlay:     return "airplayaudio"
        case .virtual:     return "waveform"
        case .thunderbolt: return "bolt.horizontal"
        case .hdmi:        return "tv"
        case .displayPort: return "tv"
        case .aggregate:   return "speaker.wave.2"
        case .unknown:     return "hifispeaker"
        }
    }
}
