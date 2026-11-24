import Foundation

enum Defaults {
    enum Key { case showLiveCanvasInDynamicIsland, enableLockScreenMediaWidget, lockScreenMusicFullscreenArtworkEnabled, lockScreenMusicFullscreenVideoArtwork }
    static var enabled = Set<Key>()
    static subscript(key: Key) -> Bool { enabled.contains(key) }
}

struct PlaybackState {
    var bundleIdentifier: String?
    var title: String
    var artist = "Artist"
    var contentIdentifier: String?
    var contentURL: String?
    var liveArtworkURL: URL?
}

enum SpotifyController {
    static let bundleIdentifier = "com.spotify.client"
    static func canonicalTrackURI(from identifier: String, spotifyURLString: String) -> String { identifier }
}

@MainActor
final class SpotifyCanvasResolver {
    var requests: [String] = []
    var callbacks: [CheckedContinuation<URL?, Never>] = []
    func canvasURL(for track: String) async -> URL? {
        requests.append(track)
        return await withCheckedContinuation { callbacks.append($0) }
    }
}

@MainActor
final class AnimatedArtworkManager {
    static let shared = AnimatedArtworkManager()
    var tracks: [String] = []
    func fetchAnimatedArtworkURL(title: String, artist: String, contentID: String?) async -> URL? {
        tracks.append(contentID ?? title)
        return URL(string: "https://fixture.invalid/apple")
    }
}

@MainActor
final class ArtworkFixture {
    var artworkConsumers: [UUID: ArtworkConsumer] = [:]
    var currentArtworkRequest: ArtworkRequest?
    var requestedArtwork: ArtworkRequest?
    var suppliedArtworkURL: URL?
    var liveArtworkTask: Task<Void, Never>?
    var liveArtworkGeneration = UUID()
    var spotifyCanvasResolver = SpotifyCanvasResolver()
    var videoArtworkURL: URL?
}

@main
enum AnimatedArtworkDemandTests {
    @MainActor
    static func main() async {
        let artwork = ArtworkFixture()
        let spotify = artwork.spotifyCanvasResolver
        let island = UUID()
        let screen = UUID()
        var state = PlaybackState(bundleIdentifier: SpotifyController.bundleIdentifier, title: "One", contentIdentifier: "1")
        artwork.updateArtworkRequest(for: state)
        artwork.setArtworkConsumer(island, kind: .island, mounted: true)
        precondition(artwork.liveArtworkTask == nil && spotify.requests.isEmpty)

        Defaults.enabled.insert(.showLiveCanvasInDynamicIsland)
        artwork.refreshLiveArtwork()
        await waitUntil { spotify.callbacks.count == 1 }
        Defaults.enabled.formUnion([.enableLockScreenMediaWidget, .lockScreenMusicFullscreenArtworkEnabled, .lockScreenMusicFullscreenVideoArtwork])
        artwork.setArtworkConsumer(screen, kind: .lockScreen, mounted: true)
        artwork.setArtworkConsumer(island, kind: .island, mounted: false)
        precondition(artwork.liveArtworkTask != nil && spotify.requests == ["1"])
        Defaults.enabled.remove(.lockScreenMusicFullscreenVideoArtwork)
        artwork.refreshLiveArtwork()
        precondition(artwork.liveArtworkTask == nil && artwork.videoArtworkURL == nil)

        artwork.setArtworkConsumer(island, kind: .island, mounted: true)
        await waitUntil { spotify.callbacks.count == 2 }
        spotify.callbacks[0].resume(returning: URL(string: "https://fixture.invalid/stale"))
        state.contentIdentifier = "2"
        artwork.updateArtworkRequest(for: state)
        await waitUntil { spotify.callbacks.count == 3 }
        spotify.callbacks[1].resume(returning: URL(string: "https://fixture.invalid/old-track"))
        let current = URL(string: "https://fixture.invalid/current")
        spotify.callbacks[2].resume(returning: current)
        await waitUntil { artwork.liveArtworkTask == nil }
        precondition(artwork.videoArtworkURL == current)

        Defaults.enabled.remove(.showLiveCanvasInDynamicIsland)
        artwork.refreshLiveArtwork()
        state = PlaybackState(bundleIdentifier: "com.apple.Music", title: "Same name", contentIdentifier: "apple-1")
        artwork.updateArtworkRequest(for: state)
        precondition(artwork.videoArtworkURL == nil && artwork.liveArtworkTask == nil)
        Defaults.enabled.insert(.showLiveCanvasInDynamicIsland)
        artwork.refreshLiveArtwork()
        await waitUntil { artwork.liveArtworkTask == nil }
        state.contentIdentifier = "apple-2"
        artwork.updateArtworkRequest(for: state)
        await waitUntil { artwork.liveArtworkTask == nil }
        precondition(AnimatedArtworkManager.shared.tracks == ["apple-1", "apple-2"])
        print("Artwork demand union, last-consumer cancellation, and stale track delivery checks passed")
    }

    @MainActor
    private static func waitUntil(_ ready: () -> Bool) async {
        for _ in 0..<400 {
            if ready() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Artwork fixture did not reach the expected state")
    }
}
