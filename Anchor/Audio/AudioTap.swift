/*
 * Atoll (DynamicIsland)
 * Original work Copyright (C) 2026 ZephyrCodesStuff (https://github.com/ZephyrCodesStuff/rtaudio)
 * Modified work Copyright (C) 2026 Atoll Contributors
 *
 * CoreAudio tap for capturing real-time audio from music applications.
 * Uses macOS 14.2+ Process Tap API for efficient audio capture.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import AudioToolbox
import CoreAudio
import QuartzCore
import simd
import os.log

private let audioTapLog = OSLog(subsystem: "com.arronlingham.Anchor", category: "AudioTap")

// Debug: track callback invocations
private var callbackCount: Int = 0

// CoreAudio fires this on a high-priority background real-time thread.
let audioIOProc: AudioDeviceIOProc = {
    inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime, clientData in

    guard let clientData = clientData else { return noErr }
    let scanner = Unmanaged<AudioTap>.fromOpaque(clientData).takeUnretainedValue()

    if scanner.isPaused { return noErr }

    let mutableInputData = UnsafeMutablePointer(mutating: inInputData)
    let bufferList = UnsafeMutableAudioBufferListPointer(mutableInputData)

    if let firstBuffer = bufferList.first, let data = firstBuffer.mData {
        // CoreAudio gives us byte size, divide by 4 (Float size) to get array length
        let floatCount = Int32(firstBuffer.mDataByteSize) / Int32(MemoryLayout<Float>.size)

        let floatData = data.assumingMemoryBound(to: Float.self)

        // Pass the mono array directly to C++
        scanner.bridge.processBuffer(floatData, count: floatCount)
        
        // Debug: log periodically with audio level info
        callbackCount += 1
        if callbackCount % 1000 == 0 {
            // Calculate max absolute value in buffer to check if audio is present
            var maxVal: Float = 0.0
            for i in 0..<Int(floatCount) {
                let absVal = abs(floatData[i])
                if absVal > maxVal { maxVal = absVal }
            }
            os_log(.debug, log: audioTapLog, "🔊 Audio callback fired %d times, buffer size: %d, max amplitude: %f", callbackCount, floatCount, maxVal)
        }
    }

    return noErr
}

private func getAudioObjectID(for pid: pid_t) -> AudioObjectID? {
    var audioObjectID: AudioObjectID = kAudioObjectUnknown
    var pidValue = pid

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

    // We query the global system object (kAudioObjectSystemObject)
    // We pass the PID as the "qualifier", and it returns the AudioObjectID
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        qualifierSize,
        &pidValue,
        &size,
        &audioObjectID
    )

    if status == noErr && audioObjectID != kAudioObjectUnknown {
        return audioObjectID
    }

    return nil
}

/// Singleton class for real-time audio capture from music apps
class AudioTap: NSObject {
    static let shared = AudioTap()
    
    let bridge = AudioBridge()
    var isPaused: Bool = false
    /// Main-thread only. Both consumers poll from main-run-loop timers, and the
    /// audioQueue paths that reset these hop to main to do it.
    private var displayMagnitudes: [Float] = Array(repeating: 0, count: 6)
    /// When `displayMagnitudes` was last advanced, so smoothing stays
    /// frame-rate independent now that it runs on demand rather than on a timer.
    /// Main-thread only, as above.
    private var lastSmoothingTick: CFTimeInterval = 0

    /// Number of visible views currently drawing the spectrum.
    ///
    /// The CoreAudio process tap is expensive in a way that does not show up in
    /// `%cpu`: it runs a real-time IO thread and keeps the audio HAL awake, which
    /// blocks deep idle for as long as it exists. It used to be created once at
    /// launch and destroyed only at quit, so on a machine with
    /// `enableRealTimeWaveform` on it ran 24/7 to feed a view that is only on
    /// screen while the notch is open and music is playing. Capture now follows
    /// its consumers: created on 0 -> 1, torn down on 1 -> 0.
    private var consumerCount = 0
    /// Set when the user turns the feature off, so a late `release()` cannot
    /// resurrect capture.
    private var isSuspended = false

    // CoreAudio stuff
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID? = nil
    private var captureIsRunning = false

    // Serial queue to prevent race conditions
    private let audioQueue = DispatchQueue(label: "com.anchor.audiotap", qos: .userInitiated)
    
    // Debounce restart requests
    private var pendingRestartWorkItem: DispatchWorkItem?

    private let targetBundleIDs = [
        "com.apple.Music",
        "com.spotify.client",
        "com.amazon.music",
        "sh.cider.genten.mac",
        "com.apple.Safari",
        "com.tidal.desktop",
        "tv.plex.plexamp",
        "com.roon.Roon",
        "com.audirvana.Audirvana-Studio",
        "com.vox.vox",
        "com.coppertino.Vox",
    ]

    private override init() {
        super.init()
    }

    /// Advances the smoothing toward the latest analyser output.
    ///
    /// This used to be a 60 Hz `Timer` on the main run loop that ran for as long
    /// as capture did — bridging an `NSArray` of `NSNumber` into `[Float]` sixty
    /// times a second whether or not anything was drawing. Both consumers poll
    /// from their own animation timers, so the work is now done when they ask
    /// for it and not before.
    ///
    /// The factor is derived from elapsed time rather than assumed to be one
    /// 60 Hz step, so a caller ticking at 30 Hz gets the same visual decay the
    /// old fixed 0.4-per-frame smoothing produced at 60 Hz.
    private func advanceSmoothing() {
        let now = CACurrentMediaTime()
        let elapsed = lastSmoothingTick == 0 ? 1.0 / 60.0 : now - lastSmoothingTick
        lastSmoothingTick = now

        // 0.4 per 1/60 s, expressed as a per-second time constant.
        let perFrame = 0.4
        let factor = Float(min(1.0, 1.0 - pow(1.0 - perFrame, elapsed * 60.0)))

        let targetLevels = bridge.getSmoothedMagnitudes()
        for i in 0..<min(targetLevels.count, displayMagnitudes.count) {
            let difference = targetLevels[i].floatValue - displayMagnitudes[i]
            displayMagnitudes[i] += difference * factor
        }
    }

    func getSmoothedMagnitudes() -> [Float] {
        guard captureIsRunning else { return displayMagnitudes }
        advanceSmoothing()
        return displayMagnitudes
    }

    /// Registers a visible consumer, starting capture if this is the first.
    ///
    /// Balance every call with `release()`. Safe to call from `onAppear`.
    func acquire() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.consumerCount += 1
            guard !self.isSuspended, self.consumerCount == 1 else { return }
            self.startCaptureSync()
        }
    }

    /// Drops a consumer, tearing capture down when the last one goes away.
    func release() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.consumerCount = max(0, self.consumerCount - 1)
            guard self.consumerCount == 0 else { return }
            self.stopCaptureSync()
        }
    }

    /// Turns the feature off wholesale (the user unticked it, or the app is
    /// quitting). Overrides the consumer count until `resume()`.
    func suspend() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.isSuspended = true
            self.stopCaptureSync()
        }
    }

    /// Re-enables capture, honouring whatever consumers are currently on screen.
    func resume() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.isSuspended = false
            guard self.consumerCount > 0 else { return }
            self.startCaptureSync()
        }
    }

    func startCapture() async {
        await withCheckedContinuation { continuation in
            audioQueue.async { [weak self] in
                self?.startCaptureSync()
                continuation.resume()
            }
        }
    }

    private func startCaptureSync() {
        guard !captureIsRunning else {
            print("⚠️ [AudioTap] Capture already running, skipping start")
            return
        }

        let runningApps = NSWorkspace.shared.runningApplications
        var targetPIDs: [AudioDeviceID] = []

        for app in runningApps {
            if let bundleID = app.bundleIdentifier, targetBundleIDs.contains(bundleID) {
                if let deviceID = getAudioObjectID(for: app.processIdentifier) {
                    targetPIDs.append(deviceID)
                    print("🎯 [AudioTap] Found \(app.localizedName ?? "App") with PID: \(app.processIdentifier), AudioObjectID: \(deviceID)")
                }
            }
        }

        if targetPIDs.isEmpty {
            print("⚠️ [AudioTap] None of our target apps are running right now.")
            return
        }

        let description = CATapDescription()
        description.processes = targetPIDs
        description.isMixdown = true
        description.isMono = true
        
        print("📋 [AudioTap] Creating tap for \(targetPIDs.count) processes: \(targetPIDs)")

        tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            print("🛑 [AudioTap] Tap Error: \(status) (\(fourCharCodeToString(status)))")
            return
        }
        print("✅ [AudioTap] Created process tap with ID: \(tapID)")

        // Get the tap's unique hardware UID
        var tapUID: CFString = "" as CFString
        var propertySize = UInt32(MemoryLayout<CFString>.stride)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        status = withUnsafeMutablePointer(to: &tapUID) { uidPtr in
            AudioObjectGetPropertyData(tapID, &propertyAddress, 0, nil, &propertySize, uidPtr)
        }
        guard status == noErr else {
            print("🛑 [AudioTap] UID Error: \(status) (\(fourCharCodeToString(status)))")
            cleanupPartialSetup()
            return
        }
        print("✅ [AudioTap] Got tap UID: \(tapUID)")

        // Create the Aggregate Device (a "virtual microphone" that we can route the tap into)
        let tapList = [[kAudioSubTapUIDKey: tapUID]]
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Atoll_Virtual_Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,  // Hides it from the user's sound settings
            kAudioAggregateDeviceTapListKey: tapList,
        ]

        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(
            aggregateDict as CFDictionary, &aggregateDeviceID)
        guard status == noErr else {
            print("🛑 [AudioTap] Aggregate Error: \(status) (\(fourCharCodeToString(status)))")
            cleanupPartialSetup()
            return
        }
        print("✅ [AudioTap] Created aggregate device with ID: \(aggregateDeviceID)")

        // Bind the Callback to the device
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        status = AudioDeviceCreateIOProcID(aggregateDeviceID, audioIOProc, selfPointer, &ioProcID)

        guard status == noErr, let validIOProcID = ioProcID else {
            print("🛑 [AudioTap] IOProc Error: \(status) (\(fourCharCodeToString(status)))")
            cleanupPartialSetup()
            return
        }
        print("✅ [AudioTap] Created IO proc")

        // Start listening
        status = AudioDeviceStart(aggregateDeviceID, validIOProcID)
        guard status == noErr else {
            print("🛑 [AudioTap] Start Error: \(status) (\(fourCharCodeToString(status)))")
            cleanupPartialSetup()
            return
        }

        captureIsRunning = true
        callbackCount = 0
        // Smoothing state belongs to the main thread — this runs on audioQueue.
        DispatchQueue.main.async { [weak self] in
            self?.lastSmoothingTick = 0
        }

        print("🟢 [AudioTap] CoreAudio CATap flowing through Aggregate Device!")
    }
    
    private func cleanupPartialSetup() {
        if let validIOProcID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, validIOProcID)
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = kAudioObjectUnknown
        aggregateDeviceID = kAudioObjectUnknown
        ioProcID = nil
    }

    func restartCapture() {
        // Cancel any pending restart
        pendingRestartWorkItem?.cancel()
        
        // Debounce: wait 500ms before actually restarting
        let workItem = DispatchWorkItem { [weak self] in
            self?.audioQueue.async {
                guard let self else { return }
                // Gate on consumers, not on `captureIsRunning`. This path fires
                // when a music app launches, and the common case is that a
                // visualiser was already on screen while `startCaptureSync()`
                // had nothing to tap — it bails when no target app is running,
                // leaving `captureIsRunning` false. Checking it here would mean
                // the waveform never starts for an app opened after the notch.
                guard !self.isSuspended, self.consumerCount > 0 else { return }
                print("🔄 [AudioTap] Restarting capture...")
                self.stopCaptureSync()
                // Small delay to let CoreAudio fully release resources
                Thread.sleep(forTimeInterval: 0.1)
                self.startCaptureSync()
            }
        }
        pendingRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    func stopCapture() {
        audioQueue.sync { [weak self] in
            self?.stopCaptureSync()
        }
    }
    
    private func stopCaptureSync() {
        guard captureIsRunning else { return }

        // Stop listening
        if let validIOProcID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, validIOProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, validIOProcID)
        }

        // Destroy resources
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }

        tapID = kAudioObjectUnknown
        aggregateDeviceID = kAudioObjectUnknown
        ioProcID = nil
        captureIsRunning = false
        // Same here: these are only ever touched on the main thread, where
        // advanceSmoothing() runs.
        DispatchQueue.main.async { [weak self] in
            self?.displayMagnitudes = Array(repeating: 0, count: 6)
            self?.lastSmoothingTick = 0
        }

        print("🔴 [AudioTap] CoreAudio CATap capture stopped")
    }
    
    var isCapturing: Bool {
        captureIsRunning
    }

    deinit {
        stopCaptureSync()
    }
}

// Helper to convert OSStatus to readable string
private func fourCharCodeToString(_ code: OSStatus) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF)
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
    return String(code)
}
