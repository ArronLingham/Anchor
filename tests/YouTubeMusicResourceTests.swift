import AppKit
import Combine
import Foundation

// Service boundaries are mocked; production controller, playback state
// and response models run unchanged. No network or media app is used.
enum YouTubeMusicError: Error { case authenticationRequired }
enum ProbeError: Error { case offline }
final class YouTubeMusicHTTPClient {
    static var response = PlaybackResponse(isPaused: true, title: "Test", artist: "Artist", album: nil,
        elapsedSeconds: 0, songDuration: 100, imageSrc: nil, repeatMode: nil, isShuffled: nil)
    init(baseURL: String) {}
    func getPlaybackInfo(token: String) async throws -> PlaybackResponse { Self.response }
    func sendCommand(endpoint: String, method: String, body: (any Codable & Sendable)?, token: String) async throws -> Data { Data() }
}
final class YouTubeMusicAuthManager {
    static var fails = false
    init(httpClient: YouTubeMusicHTTPClient) {}
    func authenticate() async throws -> String { if Self.fails { throw ProbeError.offline }; return "test" }
    func invalidateToken() async {}
}
final class YouTubeMusicWebSocketClient {
    static var connections = 0
    init(onMessage: @escaping (Data) async -> Void,
         onDisconnect: @escaping (URLSessionWebSocketTask.CloseCode?, Data?) async -> Void) {}
    func connect(to url: URL, with token: String) async throws { Self.connections += 1 }
    func disconnect() async {}
}
enum WebSocketURLBuilder {
    static func buildURL(from baseURL: String, with token: String) -> URL? { URL(string: "ws://localhost/test") }
}
actor ImageService {
    static let shared = ImageService()
    private(set) var fetches = 0
    func fetchImageData(from url: URL) async throws -> Data {
        fetches += 1
        try await Task.sleep(for: .milliseconds(10))
        return Data(url.absoluteString.utf8)
    }
}

@main struct YouTubeMusicResourceTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        var passed = 0, failed = 0
        func check(_ title: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed += 1; print("FAIL: \(title)") }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(150)) }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier != nil }),
              let identifier = app.bundleIdentifier else { fatalError("A running macOS app is required") }
        let config = YouTubeMusicConfiguration(baseURL: "http://localhost/mock", bundleIdentifier: identifier,
            reconnectDelay: 0.02...0.04, updateInterval: 100)
        var controller: YouTubeMusicController? = YouTubeMusicController(configuration: config)
        await settle()
        YouTubeMusicHTTPClient.response = PlaybackResponse(isPaused: false, title: "Song", artist: "Artist", album: nil,
            elapsedSeconds: 1, songDuration: 100, imageSrc: "https://example.invalid/art.png", repeatMode: nil, isShuffled: nil)
        for _ in 0..<20 { await controller?.updatePlaybackInfo() }
        await settle()
        check("unchanged metadata shares artwork request", await ImageService.shared.fetches == 1)
        check("artwork arrives", controller?.playbackState.artwork != nil)
        let before = YouTubeMusicWebSocketClient.connections
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: app])
        await settle()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: app])
        await settle()
        check("app launch observation survives a termination", YouTubeMusicWebSocketClient.connections > before)
        weak var oldController = controller
        controller = nil
        await settle()
        check("source switch releases controller and observers", oldController == nil)
        YouTubeMusicAuthManager.fails = true
        var retrying: YouTubeMusicController? = YouTubeMusicController(configuration: config)
        await settle()
        weak var oldRetrying = retrying
        retrying = nil
        await settle()
        check("offline retries do not retain controller", oldRetrying == nil)
        let empty = PlaybackState(bundleIdentifier: "test")
        check("idle player has no placeholder metadata", empty.title.isEmpty && empty.artist.isEmpty && empty.album.isEmpty)
        print("\(passed) media resource checks passed; \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
