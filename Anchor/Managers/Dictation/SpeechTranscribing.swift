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

/// A streaming speech-to-text backend.
///
/// Anchor uses Apple's on-device `SpeechAnalyzer` (see `AppleSpeechTranscriber`),
/// but the dictation manager only talks to this protocol so a different engine —
/// WhisperKit, whisper.cpp, a cloud API — can be swapped in without touching the
/// audio capture, hotkey, or text-injection code.
protocol SpeechTranscribing: AnyObject {
    /// Audio format the backend wants buffers converted to, or nil for "any".
    var preferredFormat: AVAudioFormat? { get async }

    /// Prepares models and returns once ready to accept audio.
    /// May download assets on first use, so it can take a while.
    func prepare() async throws

    /// Begins a transcription session. Partial and final results arrive on
    /// `onUpdate` until `finish()` is called.
    func start(onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void) async throws

    /// Feeds captured microphone audio into the session.
    ///
    /// Deliberately synchronous and safe to call from the real-time audio thread:
    /// hopping through a `Task` would give no ordering guarantee between buffers,
    /// which scrambles the transcript. Implementations must not block.
    func append(_ buffer: AVAudioPCMBuffer)

    /// Ends the session and returns the complete transcript.
    func finish() async throws -> String

    /// Aborts without producing a transcript.
    func cancel() async
}

/// One transcription callback.
struct TranscriptUpdate: Sendable {
    /// Everything finalized so far this session.
    let settledText: String
    /// The in-flight utterance, which may still change. Empty when nothing is pending.
    let volatileText: String

    var combined: String {
        let pieces = [settledText, volatileText]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return pieces.joined(separator: " ")
    }
}

enum SpeechTranscribingError: LocalizedError {
    case localeUnsupported(String)
    case assetInstallationFailed(String)
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .localeUnsupported(let identifier):
            return String(
                format: String(localized: "Dictation is not available for %@."), identifier)
        case .assetInstallationFailed(let reason):
            return String(
                format: String(localized: "Could not download the speech model: %@"), reason)
        case .notPrepared:
            return String(localized: "The speech engine was not ready.")
        }
    }
}
