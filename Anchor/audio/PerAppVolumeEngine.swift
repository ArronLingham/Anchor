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
import CoreAudio
import Foundation
import os

/// Per-app *volume*, as opposed to the per-app mute in `PerAppAudioManager`.
///
/// ## Why this is more than a property write
///
/// CoreAudio has no per-process volume. `kAudioProcessProperty*` covers a
/// process's PID, bundle identifier, devices and whether it is running — and
/// nothing else. The only route to arbitrary gain is the one this file takes:
///
/// 1. Tap the process with `muteBehavior = .mutedWhenTapped`, so its audio stops
///    reaching the output device but still reaches us.
/// 2. Build a private aggregate device out of the real output device and that
///    tap.
/// 3. Run an IOProc on the aggregate that reads the tap's input, multiplies it
///    by the gain, and writes it to the output.
///
/// This is what every app with a working volume mixer does. It notably does
/// **not** need a HAL plug-in in `/Library/Audio/Plug-Ins/HAL` or an admin
/// install — a note in this project's CLAUDE.md said otherwise and was wrong.
/// What it does need is the **audio-capture** grant, exactly as the mute path
/// does.
///
/// ## The risk this file carries, stated plainly
///
/// An IOProc sits in the real-time path of everything the user hears, and a
/// mistake here is distortion or silence rather than a misdrawn pixel. Three
/// things bound that:
///
/// - **It is opt-in per app and off by default.** A gain of exactly 1.0 tears
///   the engine down rather than running a no-op multiply.
/// - **Every failure falls back to not intervening.** If the tap, the aggregate
///   device or the IOProc cannot be created, the app is left on normal system
///   audio at full volume — never muted-with-nothing-replacing-it, which is the
///   one outcome that would look like broken hardware.
/// - **The OS owns the teardown.** Taps and aggregate devices belong to this
///   process; if Anchor crashes, they go with it and audio returns by itself.
///
/// > **This has not been verified by listening to it.** It is verified to build
/// > the device, start the IOProc and pass frames, and to tear all of that down
/// > cleanly — but whether it *sounds* right needs a person with speakers.
final class PerAppVolumeEngine {
    private static let log = OSLog(
        subsystem: "com.arronlingham.Anchor", category: "perAppVolume")

    /// One process being re-rendered.
    private final class Session {
        let pid: pid_t
        var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        /// Read on the real-time thread. `Atomic` would be neater; a plain
        /// `Float` written from the main thread is safe here because a torn
        /// read of a 32-bit float cannot occur on arm64 and the worst case is
        /// one buffer at the previous gain.
        var gain: Float = 1

        init(pid: pid_t) { self.pid = pid }
    }

    private var sessions: [pid_t: Session] = [:]

    // MARK: - Public

    /// Applies `gain` (0…2, where 1 is untouched) to `app`.
    ///
    /// Returns false when the engine could not be built, which the caller must
    /// treat as "this app is at normal volume" rather than silently assuming it
    /// worked.
    @discardableResult
    func setGain(_ gain: Float, for app: AudioApp) -> Bool {
        // Exactly 1.0 means "leave it alone", and leaving it alone means no
        // tap, no aggregate device and no real-time thread at all.
        guard abs(gain - 1) > 0.001 else {
            stop(pid: app.pid)
            return true
        }

        if let existing = sessions[app.pid] {
            existing.gain = gain
            return true
        }

        guard let session = start(for: app, gain: gain) else {
            os_log("per-app volume: could not start for %{public}s",
                   log: Self.log, type: .error, app.name)
            return false
        }
        sessions[app.pid] = session
        return true
    }

    func gain(for pid: pid_t) -> Float {
        sessions[pid]?.gain ?? 1
    }

    func isActive(pid: pid_t) -> Bool {
        sessions[pid] != nil
    }

    /// Stops re-rendering one app, returning it to normal system audio.
    func stop(pid: pid_t) {
        guard let session = sessions.removeValue(forKey: pid) else { return }
        teardown(session)
    }

    func stopAll() {
        for pid in sessions.keys { stop(pid: pid) }
    }

    /// Drops sessions whose process has exited.
    func reconcile(livePIDs: Set<pid_t>) {
        for pid in sessions.keys where !livePIDs.contains(pid) {
            stop(pid: pid)
        }
    }

    // MARK: - Building

    private func start(for app: AudioApp, gain: Float) -> Session? {
        let session = Session(pid: app.pid)
        session.gain = gain

        // 1. Tap the process, muting it at the device so only our re-render is
        //    audible. Without `.mutedWhenTapped` the user hears both.
        let description = CATapDescription(
            stereoMixdownOfProcesses: [app.objectID])
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        description.name = "Anchor volume — \(app.name)"

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        // Status alone is not success: without the audio-capture grant this
        // returns noErr and an unknown ID. That is documented in CLAUDE.md and
        // was found the hard way.
        guard tapStatus == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            os_log("per-app volume: tap failed, status %d", log: Self.log, type: .error, tapStatus)
            return nil
        }
        session.tapID = tapID

        guard let outputUID = Self.defaultOutputDeviceUID() else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        let tapUID = description.uuid.uuidString

        // 2. A private aggregate of the real output plus that tap. Private so
        //    it never appears in the user's Sound settings.
        let aggregateUID = UUID().uuidString
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Anchor Volume \(app.pid)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            composition as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr,
              aggregateID != AudioObjectID(kAudioObjectUnknown)
        else {
            os_log("per-app volume: aggregate failed, status %d",
                   log: Self.log, type: .error, aggregateStatus)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        session.aggregateID = aggregateID

        // 3. The IOProc. Everything it touches is captured by reference and
        //    read-only from the real-time thread except `gain`.
        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID, aggregateID, nil
        ) { [weak session] _, inInputData, _, outOutputData, _ in
            guard let session else { return }
            Self.render(
                input: inInputData,
                output: outOutputData,
                gain: session.gain)
        }

        guard ioStatus == noErr, let ioProcID else {
            os_log("per-app volume: IOProc failed, status %d",
                   log: Self.log, type: .error, ioStatus)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        session.ioProcID = ioProcID

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            os_log("per-app volume: start failed, status %d",
                   log: Self.log, type: .error, startStatus)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        os_log("per-app volume: engaged for %{public}s at %.2f",
               log: Self.log, type: .info, app.name, Double(gain))
        return session
    }

    /// The real-time callback.
    ///
    /// Deliberately allocation-free and lock-free: it runs on CoreAudio's
    /// real-time thread, where a malloc or a mutex is a dropout.
    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        gain: Float
    ) {
        let inBuffers = UnsafeBufferPointer<AudioBuffer>(
            start: withUnsafePointer(to: input.pointee.mBuffers) {
                UnsafeRawPointer($0).assumingMemoryBound(to: AudioBuffer.self)
            },
            count: Int(input.pointee.mNumberBuffers))

        let outBuffers = UnsafeMutableBufferPointer<AudioBuffer>(
            start: withUnsafeMutablePointer(to: &output.pointee.mBuffers) {
                UnsafeMutableRawPointer($0).assumingMemoryBound(to: AudioBuffer.self)
            },
            count: Int(output.pointee.mNumberBuffers))

        for index in outBuffers.indices {
            var out = outBuffers[index]
            guard let outData = out.mData else { continue }

            // No matching input buffer: write silence rather than whatever was
            // left in the buffer, which would be a burst of noise.
            guard index < inBuffers.count,
                  let inData = inBuffers[index].mData,
                  inBuffers[index].mNumberChannels == out.mNumberChannels
            else {
                memset(outData, 0, Int(out.mDataByteSize))
                continue
            }

            let frames = Int(min(out.mDataByteSize, inBuffers[index].mDataByteSize))
                / MemoryLayout<Float>.size
            let source = inData.assumingMemoryBound(to: Float.self)
            let destination = outData.assumingMemoryBound(to: Float.self)

            for frame in 0..<frames {
                // Hard-clipped: a gain above 1 on already-loud material would
                // otherwise wrap and sound like tearing.
                let scaled = source[frame] * gain
                destination[frame] = max(-1, min(1, scaled))
            }
            out.mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
        }
    }

    // MARK: - Teardown

    /// Order matters: stop the IOProc before destroying what it reads from.
    private func teardown(_ session: Session) {
        if let ioProcID = session.ioProcID,
           session.aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(session.aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(session.aggregateID, ioProcID)
        }
        if session.aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(session.aggregateID)
        }
        if session.tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(session.tapID)
        }
    }

    // MARK: - CoreAudio helpers

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, &deviceID) == noErr,
            deviceID != AudioObjectID(kAudioObjectUnknown)
        else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutableBytes(of: &uid) { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kAudio_ParamError }
            return AudioObjectGetPropertyData(
                deviceID, &uidAddress, 0, nil, &uidSize, base)
        }
        guard status == noErr else { return nil }
        return uid as String
    }
}
