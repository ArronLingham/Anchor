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
                self.deliver(transcript)
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

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let level = Self.peakLevel(of: buffer)
            Task { @MainActor in self.updateLevel(level) }

            guard let converted = self.convert(buffer) else { return }
            Task { await self.backend.append(converted) }
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

    /// Resamples the microphone buffer into the format the backend asked for.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let targetFormat else { return buffer }

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

    // MARK: - Delivery

    private func deliver(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset()
            return
        }

        do {
            try TextInjector.insert(trimmed)
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

    private nonisolated static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var peak: Float = 0
        for index in 0..<count {
            peak = max(peak, abs(channel[index]))
        }
        // Perceptual curve — raw peak amplitude looks far too flat on a meter.
        return min(1, sqrt(peak))
    }
}
