import Foundation
import CoreGraphics

@main
struct ExternalPillPolicyTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool) { precondition(condition); checks += 1 }
        for enabled in [false, true] {
            for top: CGFloat? in [nil, 0, 32] {
                let persistent = ExternalPillPolicy.isPersistent(enabled: enabled, safeAreaTop: top)
                check(persistent == (enabled && top == 0))
                for detected in [false, true] {
                    for detection in [false, true] {
                        check(ExternalPillPolicy.hidesForFullscreen(detected: detected, detectionEnabled: detection, persistent: persistent) == (detected && detection && !persistent))
                    }
                }
                for height: CGFloat in [0, 24, 32, 40] {
                    let input = CGSize(width: 150, height: height)
                    let result = ExternalPillPolicy.closedSize(input, persistent: persistent)
                    check(result.height == (persistent ? max(32, height) : height))
                    check(result.width == 150)
                }
            }
        }
        check(ExternalPillPolicy.closedSize(.zero, persistent: true) == CGSize(width: 80, height: 32))
        print("External pill: \(checks) checks passed")
    }
}
