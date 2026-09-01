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

/// Protocol for RT-safe biquad audio processors.
///
/// Captures the read-only interface that audio callbacks use.
/// Concrete types should be used in the actual audio path to avoid
/// existential boxing overhead. This protocol enables testing and
/// future pipeline composition.
///
/// ## RT-Safety Contract
/// `process()` and `isEnabled` MUST be safe to call on CoreAudio's
/// HAL I/O thread: no allocations, locks, ObjC, logging, or I/O.
protocol BiquadProcessable: AnyObject {
    /// Whether processing is currently active (RT-safe atomic read).
    var isEnabled: Bool { get }

    /// Process stereo interleaved audio. RT-safe.
    /// Can process in-place (input == output).
    ///
    /// - Parameters:
    ///   - input: Input buffer (stereo interleaved Float32).
    ///   - output: Output buffer (stereo interleaved Float32).
    ///   - frameCount: Number of stereo frames (total samples / 2).
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int)

    /// Update the device sample rate. Call from main thread only.
    func updateSampleRate(_ newRate: Double)
}
