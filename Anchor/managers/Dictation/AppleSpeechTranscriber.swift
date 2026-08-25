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
import Foundation
import os
import Speech

/// On-device transcription via macOS 26's `SpeechAnalyzer` / `SpeechTranscriber`.
///
/// Runs on the Neural Engine: no network, no API key, no model shipped in the
/// bundle (assets are fetched once through `AssetInventory`).
///
/// Two behaviours of the API worth knowing, both learned the hard way:
///  - `results` must be drained concurrently with feeding audio, or the analyzer
///    stalls waiting for the consumer.
///  - The `.progressiveTranscription` preset emits *cumulative* volatile results —
///    each element is the whole in-flight utterance, not a delta — while finalized
///    results arrive once per utterance. Concatenating everything duplicates text,
///    so settled and volatile parts are tracked separately here.
final class AppleSpeechTranscriber: SpeechTranscribing {
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputStream: AsyncStream<AnalyzerInput>?
    private var resultsTask: Task<Void, Never>?

    /// Written on the main actor, read from the real-time audio thread, so it
    /// needs a lock rather than plain property access.
    private let continuationLock = OSAllocatedUnfairLock<AsyncStream<AnalyzerInput>.Continuation?>(
        initialState: nil)

    private let state = TranscriptState()

    var preferredFormat: AVAudioFormat? {
        get async {
            guard let transcriber else { return nil }
            return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        }
    }

    // MARK: - Lifecycle

    func prepare() async throws {
        let preferred = Locale.current
        guard let locale = await Self.resolveLocale(preferred) else {
            throw SpeechTranscribingError.localeUnsupported(preferred.identifier)
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            do {
                let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber])
                try await request?.downloadAndInstall()
            } catch {
                throw SpeechTranscribingError.assetInstallationFailed(error.localizedDescription)
            }
        }
    }

    /// Picks the closest supported locale to the user's, falling back to any
    /// English variant and finally to whatever the system does support.
    private static func resolveLocale(_ preferred: Locale) async -> Locale? {
        if let exact = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) {
            return exact
        }
        let supported = await SpeechTranscriber.supportedLocales
        if let english = supported.first(where: { $0.language.languageCode?.identifier == "en" }) {
            return english
        }
        return supported.first
    }

    func start(onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void) async throws {
        guard let transcriber else { throw SpeechTranscribingError.notPrepared }

        await state.reset()

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputStream = stream
        continuationLock.withLock { $0 = continuation }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Drain results concurrently — see the note in the type doc.
        let state = self.state
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let update = await state.apply(text: text, isFinal: result.isFinal)
                    onUpdate(update)
                }
            } catch {
                NSLog("AppleSpeechTranscriber: results stream ended: \(error)")
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    /// Safe to call from the audio thread: `yield` is thread-safe and preserves
    /// call order, so buffers reach the analyzer in the order they were captured.
    func append(_ buffer: AVAudioPCMBuffer) {
        continuationLock.withLock { $0?.yield(AnalyzerInput(buffer: buffer)) }
    }

    func finish() async throws -> String {
        finishInput()

        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        // Let the results task drain whatever finalization produced.
        await resultsTask?.value

        let transcript = await state.finalTranscript()
        teardown()
        return transcript
    }

    func cancel() async {
        finishInput()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        teardown()
    }

    /// Closes the audio stream, so no further `append` can enqueue into it.
    private func finishInput() {
        continuationLock.withLock { continuation in
            continuation?.finish()
            continuation = nil
        }
    }

    private func teardown() {
        resultsTask = nil
        analyzer = nil
        inputStream = nil
    }
}

/// Serialises the settled/volatile split across the results task and callers.
private actor TranscriptState {
    private var settled: [String] = []
    private var volatileText = ""

    func reset() {
        settled.removeAll()
        volatileText = ""
    }

    func apply(text: String, isFinal: Bool) -> TranscriptUpdate {
        if isFinal {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { settled.append(trimmed) }
            volatileText = ""
        } else {
            volatileText = text
        }
        return TranscriptUpdate(settledText: settled.joined(separator: " "), volatileText: volatileText)
    }

    func finalTranscript() -> String {
        var pieces = settled
        let trimmedVolatile = volatileText.trimmingCharacters(in: .whitespaces)
        if !trimmedVolatile.isEmpty { pieces.append(trimmedVolatile) }
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
