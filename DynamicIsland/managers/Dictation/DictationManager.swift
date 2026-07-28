/*
 * Atoll (DynamicIsland)
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
import Combine
import Defaults
import Foundation

/// Push-to-talk dictation: hold the shortcut, speak, release, and the transcript
/// is pasted into the focused app.
///
/// Audio capture is `AVAudioEngine` in-process, transcription is whatever
/// `SpeechTranscribing` backend is injected (Apple's on-device engine by
/// default), and delivery is `TextInjector`. Nothing runs while idle — the engine
/// is only started for the duration of a dictation.
@MainActor
final class DictationManager: ObservableObject {
    static let shared = DictationManager()

    enum State: Equatable {
        case idle
        case preparing
        case listening
        case transcribing
        case failed(String)

        var isActive: Bool {
            switch self {
            case .idle, .failed: return false
            case .preparing, .listening, .transcribing: return true
            }
        }
    }

    @Published private(set) var state: State = .idle
    /// Live transcript shown in the notch while dictating.
    @Published private(set) var liveTranscript: String = ""
    /// Smoothed input level, 0...1, for the waveform.
    @Published private(set) var inputLevel: Float = 0

    private let engine = AVAudioEngine()
    private var backend: SpeechTranscribing
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isPrepared = false
    private var errorResetTask: Task<Void, Never>?

    private init(backend: SpeechTranscribing = AppleSpeechTranscriber()) {
        self.backend = backend
    }

    // MARK: - Public API

    /// Called on hotkey press.
    func beginDictation() {
        guard Defaults[.enableDictation] else { return }
        guard !state.isActive else { return }

        errorResetTask?.cancel()
        liveTranscript = ""
        state = .preparing

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startSession()
                self.state = .listening
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    /// Called on hotkey release.
    func endDictation() {
        guard state == .listening || state == .preparing else { return }
        state = .transcribing
        stopEngine()

        Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await self.backend.finish()
                await self.deliver(transcript)
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    /// Abandons an in-flight dictation without pasting.
    func cancelDictation() {
        guard state.isActive else { return }
        stopEngine()
        Task { [weak self] in
            await self?.backend.cancel()
            self?.reset()
        }
    }

    // MARK: - Session

    private func startSession() async throws {
        if !isPrepared {
            try await backend.prepare()
            isPrepared = true
        }

        try await backend.start { [weak self] update in
            Task { @MainActor in
                self?.liveTranscript = update.combined
            }
        }

        targetFormat = await backend.preferredFormat
        try startEngine()
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        if let targetFormat, targetFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }

        // Captured by value so the audio thread never reads main-actor state.
        let backend = self.backend
        let capturedConverter = converter
        let capturedTarget = targetFormat

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            let level = Self.peakLevel(of: buffer)
            Task { @MainActor [weak self] in self?.updateLevel(level) }

            // Hand the analyzer a buffer we own. AVAudioEngine reuses the buffer it
            // gives the tap once this closure returns, and the analyzer consumes it
            // asynchronously — passing the original through would be a use-after-free.
            guard
                let owned = Self.convertedCopy(
                    of: buffer, using: capturedConverter, targetFormat: capturedTarget)
            else { return }
            // Synchronous, so buffers stay in capture order.
            backend.append(owned)
        }

        engine.prepare()
        try engine.start()
    }

    private func stopEngine() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputLevel = 0
    }

    /// Resamples the microphone buffer into the format the backend asked for,
    /// always returning a buffer this app owns.
    ///
    /// Static, and takes the converter explicitly, so the audio thread never
    /// touches main-actor state. The tap closure captures both at install time.
    private nonisolated static func convertedCopy(
        of buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        targetFormat: AVAudioFormat?
    ) -> AVAudioPCMBuffer? {
        guard let converter, let targetFormat else { return copy(of: buffer) }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        if let error {
            NSLog("DictationManager: audio conversion failed: \(error)")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }

    /// Deep-copies a tap buffer so it outlives the tap callback.
    private nonisolated static func copy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard
            let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength

        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: frames)
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: frames)
            }
        } else if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: frames)
            }
        } else {
            return nil
        }
        return copy
    }

    // MARK: - Delivery

    private func deliver(_ transcript: String) async {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset()
            return
        }

        do {
            try await TextInjector.insert(trimmed)
            reset()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func reset() {
        state = .idle
        liveTranscript = ""
        inputLevel = 0
    }

    private func fail(_ message: String) {
        NSLog("DictationManager: \(message)")
        stopEngine()
        state = .failed(message)
        liveTranscript = ""
        errorResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.reset()
        }
    }

    // MARK: - Level metering

    private func updateLevel(_ peak: Float) {
        // Asymmetric smoothing: rise quickly so the waveform feels responsive,
        // fall slowly so it does not flicker between syllables.
        let smoothing: Float = peak > inputLevel ? 0.5 : 0.15
        inputLevel += (peak - inputLevel) * smoothing
    }

    /// Handles float and Int16 mic formats; reading only `floatChannelData` would
    /// silently report a flat zero level on hardware that reports integer samples.
    private nonisolated static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var peak: Float = 0
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<count { peak = max(peak, abs(channel[index])) }
        } else if let channel = buffer.int16ChannelData?[0] {
            for index in 0..<count {
                peak = max(peak, abs(Float(channel[index])) / Float(Int16.max))
            }
        } else {
            return 0
        }
        // Perceptual curve — raw peak amplitude looks far too flat on a meter.
        return min(1, sqrt(peak))
    }
}
