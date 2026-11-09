import Foundation

/// Distinguishes work accepted before and after the assistant is disabled.
/// Invalidation also works when a preference notification arrives off main.
final class AIAssistantSession: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
    }

    func token() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func allows(_ token: UInt64, enabled: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && token == generation
    }
}
