import AVFoundation
import Foundation

enum LockChime: String, CaseIterable, Sendable { case lock, unlock }

/// Audio players and their preparation belong exclusively to this serial
/// queue. The small request token is the only state shared across queues.
final class LockSoundAudio: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Anchor.lock-sound", qos: .userInteractive)
    private let requestLock = NSLock()
    private var latestRequest = UUID()
    private var players: [LockChime: AVAudioPlayer] = [:]
    private var playbackOffsets: [LockChime: TimeInterval] = [:]
    private var lastPlayed: [LockChime: TimeInterval] = [:]
    private let resourceURL: @Sendable (LockChime) -> URL?

    init(resourceURL: @escaping @Sendable (LockChime) -> URL? = {
        Bundle.main.url(forResource: $0.rawValue, withExtension: "mp3")
    }) {
        self.resourceURL = resourceURL
    }

    func prepare(completion: (@Sendable ([LockChime: TimeInterval]) -> Void)? = nil) {
        queue.async {
            for type in LockChime.allCases { _ = self.player(for: type) }
            completion?(self.playbackOffsets)
        }
    }

    func play(_ type: LockChime) {
        let token = UUID()
        let requestedAt = ProcessInfo.processInfo.systemUptime
        requestLock.withLock { latestRequest = token }
        queue.async {
            guard self.isCurrent(token, requestedAt: requestedAt),
                  let player = self.player(for: type),
                  self.isCurrent(token, requestedAt: requestedAt) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - (self.lastPlayed[type] ?? -.infinity) >= 0.25 else { return }
            for (other, audio) in self.players where other != type { audio.stop() }
            player.currentTime = self.playbackOffsets[type] ?? 0
            player.play()
            self.lastPlayed[type] = now
        }
    }

    private func isCurrent(_ token: UUID, requestedAt: TimeInterval) -> Bool {
        requestLock.withLock { latestRequest == token }
            && ProcessInfo.processInfo.systemUptime - requestedAt <= 0.35
    }

    private func player(for type: LockChime) -> AVAudioPlayer? {
        if let cached = players[type] { return cached }
        guard let url = resourceURL(type) else { return nil }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.prepareToPlay() else { return nil }
            players[type] = player
            playbackOffsets[type] = leadingSilence(in: url)
            return player
        } catch {
            NSLog("LockSoundAudio: could not prepare %@: %@", type.rawValue, error.localizedDescription)
            return nil
        }
    }

    /// The bundled lock MP3 has about 228 ms of leading silence. Decode only
    /// during preparation and retain a short lead-in so the attack stays intact.
    private func leadingSilence(in url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let frames = AVAudioFrameCount(min(file.length, AVAudioFramePosition(file.processingFormat.sampleRate * 2)))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil, let channels = buffer.floatChannelData else { return 0 }
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<Int(buffer.format.channelCount) where abs(channels[channel][frame]) > 0.005 {
                return max(0, Double(frame) / buffer.format.sampleRate - 0.015)
            }
        }
        return 0
    }
}
