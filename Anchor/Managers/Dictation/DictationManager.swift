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
import AppKit
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

    /// Values that change many times a second while dictating.
    ///
    /// Deliberately a separate observable. `ContentView` has to watch `state`
    /// to know whether to show the live activity at all, and it is a single
    /// 2,400-line view — publishing the level meter from the same object made
    /// the entire notch re-render at meter rate for the whole dictation.
    /// Only `DictationLiveActivity` observes this.
    let live = LiveOutput()

    @MainActor
    final class LiveOutput: ObservableObject {
        /// Live transcript shown in the notch while dictating.
        @Published fileprivate(set) var transcript: String = ""
        /// Smoothed input level, 0...1, for the waveform.
        @Published fileprivate(set) var inputLevel: Float = 0
    }

    private let engine = AVAudioEngine()
    private let makeBackend: @MainActor () -> SpeechTranscribing
    private var backend: SpeechTranscribing?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isPrepared = false
    private var tapInstalled = false
    private var sessionTask: Task<Void, Never>?
    private var errorResetTask: Task<Void, Never>?
    private var sessionToken = 0
    private var preferenceObservers = Set<AnyCancellable>()

    private init(makeBackend: @escaping @MainActor () -> SpeechTranscribing = { AppleSpeechTranscriber() }) {
        self.makeBackend = makeBackend
        Publishers.Merge(
            Defaults.publisher(.enableDictation, options: []).map(\.newValue),
            Defaults.publisher(.enableShortcuts, options: []).map(\.newValue)
        )
        .filter { !$0 }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.cancelDictation() }
        .store(in: &preferenceObservers)
    }

    // MARK: - Public API

    /// Called on hotkey press.
    func beginDictation() {
        guard Self.isEnabled, !state.isActive else { return }

        errorResetTask?.cancel()
        live.transcript = ""
        let backend = makeBackend()
        self.backend = backend
        sessionToken += 1
        let token = sessionToken
        state = .preparing

        sessionTask = Task { [weak self] in
            guard let self, self.acceptsSession(token) else { return }
            do {
                try await self.startSession(token: token, backend: backend)
                if self.acceptsSession(token) {
                    self.state = .listening
                }
            } catch {
                guard self.acceptsSession(token) else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    /// Called on hotkey release.
    func endDictation() {
        if !Self.isEnabled || state == .preparing {
            cancelDictation()
            return
        }
        guard state == .listening, let backend else { return }
        let token = sessionToken
        state = .transcribing
        stopEngine()

        sessionTask = Task { [weak self] in
            guard let self, self.acceptsSession(token) else { return }
            do {
                let transcript = try await backend.finish()
                guard self.acceptsSession(token) else { return }
                await self.deliver(transcript, token: token)
            } catch {
                guard self.acceptsSession(token) else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    /// Abandons an in-flight dictation without pasting.
    func cancelDictation() {
        guard state != .idle else { return }
        retireSession()
        reset()
    }

    private func retireSession() {
        sessionToken += 1
        sessionTask?.cancel()
        sessionTask = nil
        errorResetTask?.cancel()
        errorResetTask = nil
        stopEngine()
        if let backend {
            self.backend = nil
            Task { await backend.cancel() }
        }
    }

    private static var isEnabled: Bool { Defaults[.enableDictation] && Defaults[.enableShortcuts] }

    private func acceptsSession(_ token: Int) -> Bool {
        sessionToken == token && Self.isEnabled && !Task.isCancelled
    }

    // MARK: - Session

    private func startSession(token: Int, backend: SpeechTranscribing) async throws {
        if !isPrepared {
            try await backend.prepare()
            guard acceptsSession(token) else { return }
            isPrepared = true
        }

        try await backend.start { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.acceptsSession(token), self.state.isActive else { return }
                self.live.transcript = update.combined
            }
        }

        guard acceptsSession(token) else { return }
        let format = await backend.preferredFormat
        guard acceptsSession(token) else { return }
        targetFormat = format
        try startEngine(backend: backend, token: token)
    }

    private func startEngine(backend: SpeechTranscribing, token: Int) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        if let targetFormat, targetFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }

        // Captured by value so the audio thread never reads main-actor state.
        let capturedConverter = converter
        let capturedTarget = targetFormat

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            let level = Self.peakLevel(of: buffer)
            Task { @MainActor [weak self] in
                guard let self, self.acceptsSession(token), self.state == .listening else { return }
                self.updateLevel(level)
            }

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
        tapInstalled = true

        engine.prepare()
        try engine.start()
    }

    private func stopEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        converter = nil
        targetFormat = nil
        live.inputLevel = 0
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

    private func deliver(_ transcript: String, token: Int) async {
        guard acceptsSession(token) else { return }
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if Defaults[.dictationTidyWhitespace] {
            text = text.replacingOccurrences(
                of: "\\s+", with: " ", options: .regularExpression)
        }
        guard !text.isEmpty else {
            reset()
            return
        }

        // Clipboard-only mode exists so dictation still works without the
        // Accessibility grant, which is the one permission people balk at.
        guard Defaults[.dictationAutoPaste] else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            playFeedback()
            reset()
            return
        }

        do {
            try await TextInjector.insert(text) { self.acceptsSession(token) }
            guard acceptsSession(token) else { return }
            playFeedback()
            reset()
        } catch {
            guard acceptsSession(token) else { return }
            fail(error.localizedDescription)
        }
    }

    private func playFeedback() {
        guard Defaults[.dictationFeedbackSound] else { return }
        NSSound(named: "Tink")?.play()
    }

    private func reset() {
        sessionTask = nil
        backend = nil
        state = .idle
        live.transcript = ""
        live.inputLevel = 0
    }

    private func fail(_ message: String) {
        NSLog("DictationManager: \(message)")
        retireSession()
        state = .failed(message)
        live.transcript = ""
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
        let smoothing: Float = peak > live.inputLevel ? 0.5 : 0.15
        live.inputLevel += (peak - live.inputLevel) * smoothing
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
