import Foundation

/// Invalidates permission callbacks and queued session starts from an older view.
/// The session queue can check the token without reading main-actor state.
final class CameraMirrorSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active = false

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        active = true
        return generation
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        active = false
    }

    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && generation == token
    }
}
