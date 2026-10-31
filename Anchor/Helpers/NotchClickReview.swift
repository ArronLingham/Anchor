#if DEBUG
import AppKit
import Foundation

/// Opt-in integration checks against ContentView's real SwiftUI layout.
/// Reports geometry and booleans only; never captures content or moves the pointer.
@MainActor
enum NotchClickReview {
    static func run(delegate: AppDelegate, directory: URL) async {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed])
        }
        func geometry(_ region: NotchClickRegion?) -> [String: Double] {
            guard let region else { return [:] }
            return ["x": region.screenFrame.minX, "y": region.screenFrame.minY,
                    "width": region.screenFrame.width, "height": region.screenFrame.height]
        }
        let originalView = AnchorViewCoordinator.shared.currentView
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AnchorViewCoordinator.shared.currentView = .home
        let pairs: [(AnchorWindow, AnchorViewModel)] = delegate.shouldUseMultiWindow
            ? delegate.windows.compactMap { screen, panel in
                guard let window = panel as? AnchorWindow, let model = delegate.viewModels[screen] else { return nil }
                return (window, model)
            }
            : (delegate.window as? AnchorWindow).map { [($0, delegate.vm)] } ?? []
        check("Live notch window exists", !pairs.isEmpty)
        var frames: [[String: Any]] = []
        for (window, model) in pairs {
            let originalFrame = window.frame
            let proposedFrame = originalFrame.insetBy(dx: -8, dy: -8)
            window.setFrame(proposedFrame, display: false)
            check("Unmanaged resize cannot change island size", window.frame.size == originalFrame.size)
            window.setManagedFrame(proposedFrame, display: false)
            check("Anchor can resize its island", window.frame.size == proposedFrame.size)
            window.setManagedFrame(originalFrame, display: false)
            let token = UUID()
            model.setAutoCloseSuppression(true, token: token)
            model.close()
            try? await Task.sleep(for: .milliseconds(650))
            window.contentView?.layoutSubtreeIfNeeded()
            let closed = window.reviewedClickRegion
            check("Closed SwiftUI surface is measured", closed != nil && closed!.bounds.height > 0)
            if let region = closed {
                let center = CGPoint(x: region.screenFrame.midX, y: region.screenFrame.midY)
                window.refreshMouseInteractivity(at: center, pressedButtons: 0)
                check("Painted closed notch accepts input", !window.ignoresMouseEvents)
                let below = CGPoint(x: window.frame.midX, y: window.frame.maxY - 110)
                window.refreshMouseInteractivity(at: below, pressedButtons: 0)
                check("Browser search area passes through closed notch", window.ignoresMouseEvents)
                window.refreshMouseInteractivity()
            }
            model.open()
            try? await Task.sleep(for: .milliseconds(1100))
            window.contentView?.layoutSubtreeIfNeeded()
            let opened = window.reviewedClickRegion
            check("Model remains open during control checks", model.notchState == .open)
            check("Open SwiftUI surface is measured", opened != nil)
            if let region = opened {
                let center = CGPoint(x: region.screenFrame.midX, y: region.screenFrame.midY)
                window.refreshMouseInteractivity(at: center, pressedButtons: 0)
                check("Open controls accept input", !window.ignoresMouseEvents)
                let side = CGPoint(x: region.screenFrame.minX - 2, y: region.screenFrame.midY)
                window.refreshMouseInteractivity(at: side, pressedButtons: 0)
                check("Open shadow margin passes input", window.ignoresMouseEvents)
                window.refreshMouseInteractivity()
            }
            if let view = window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("opened-notch.png"))
            }
            AnchorViewCoordinator.shared.currentView = .timer
            try? await Task.sleep(for: .milliseconds(1100))
            window.contentView?.layoutSubtreeIfNeeded()
            let timer = window.reviewedClickRegion
            check("Timer tab keeps its painted controls interactive", timer != nil && model.notchState == .open)
            if let region = timer {
                let lowerControl = CGPoint(x: region.screenFrame.midX, y: region.screenFrame.minY + 20)
                window.refreshMouseInteractivity(at: lowerControl, pressedButtons: 0)
                check("Lower controls are inside the measured region", !window.ignoresMouseEvents)
                window.refreshMouseInteractivity()
            }
            AnchorViewCoordinator.shared.currentView = .home
            model.close()
            try? await Task.sleep(for: .milliseconds(650))
            let closedAgain = window.reviewedClickRegion
            check("Closing shrinks the measured input surface", closedAgain != nil && opened != nil
                  && closedAgain!.screenFrame.height < opened!.screenFrame.height)
            frames.append(["closed": geometry(closed), "opened": geometry(opened),
                           "timer": geometry(timer), "closedAgain": geometry(closedAgain)])
            model.setAutoCloseSuppression(false, token: token)
        }
        delegate.setUtilityIslandActive(true)
        check("Advanced island takeover releases native input", pairs.allSatisfy { $0.0.ignoresMouseEvents })
        delegate.setUtilityIslandActive(false)
        try? await Task.sleep(for: .milliseconds(200))
        check("Native handback uses the painted region", pairs.allSatisfy { window, _ in
            window.refreshMouseInteractivity()
            return window.ignoresMouseEvents == !window.containsInteractivePoint(NSEvent.mouseLocation)
        })
        AnchorViewCoordinator.shared.currentView = originalView
        let failures = checks.filter { ($0["passed"] as? Bool) != true }.count
        let report: [String: Any] = ["checks": checks, "failures": failures, "frames": frames,
                                   "pointerMoved": false, "screenLocked": false]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("click-routing.json"), options: .atomic)
        }
        NSApp.terminate(nil)
    }
}
#endif
