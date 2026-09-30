import Foundation
import CoreGraphics

/// The persistent option takes precedence over automatic hiding on unnotched displays.
enum ExternalPillPolicy {
    static func isPersistent(enabled: Bool, safeAreaTop: CGFloat?) -> Bool {
        enabled && safeAreaTop.map { $0 <= 0 } == true
    }

    static func hidesForFullscreen(detected: Bool, detectionEnabled: Bool, persistent: Bool) -> Bool {
        detectionEnabled && detected && !persistent
    }

    static func closedSize(_ size: CGSize, persistent: Bool) -> CGSize {
        guard persistent else { return size }
        // Auto-hidden menu bars and zero custom heights must not erase the pill.
        return CGSize(width: max(80, size.width), height: max(32, size.height))
    }
}
