import Foundation

/// Tokens invalidate delayed work whenever the lock-screen panel changes lifecycle.
struct LockScreenPresentationState {
    private(set) var generation = UUID()
    private(set) var isRequested = false
    private(set) var mediaAvailable = false

    mutating func present() -> UUID { generation = UUID(); isRequested = true; return generation }
    mutating func hide() -> UUID { generation = UUID(); isRequested = false; return generation }
    mutating func setMediaAvailable(_ available: Bool) { mediaAvailable = available }
    func shouldBeVisible(isLocked: Bool, isEnabled: Bool) -> Bool { isRequested && mediaAvailable && isLocked && isEnabled }
    func canPresent(_ token: UUID) -> Bool { isRequested && generation == token }
    func canFinishHiding(_ token: UUID) -> Bool { !isRequested && generation == token }
}
