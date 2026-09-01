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

@MainActor
protocol AudioDeviceProviding: AnyObject {
    var outputDevices: [AudioDevice] { get }
    var inputDevices: [AudioDevice] { get }

    var onDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)? { get set }
    var onDeviceConnected: ((_ uid: String, _ name: String) -> Void)? { get set }
    var onInputDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)? { get set }
    var onInputDeviceConnected: ((_ uid: String, _ name: String) -> Void)? { get set }

    func device(for uid: String) -> AudioDevice?
    func inputDevice(for uid: String) -> AudioDevice?

    func start()
    func stop()
}
