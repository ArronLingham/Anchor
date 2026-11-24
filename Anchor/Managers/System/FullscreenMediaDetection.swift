/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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

import ApplicationServices
import Combine
import Defaults
import MacroVisionKit
import SwiftUI

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    private lazy var detector: MacroVisionKit = {
        let detector = MacroVisionKit.shared
        detector.configuration.includeSystemApps = true
        return detector
    }()
    @Published private(set) var fullscreenStatus: [String: Bool] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var preferences = Set<AnyCancellable>()
    private var scan: DispatchWorkItem?
    private var generation = UUID()

    private init() {
        Defaults.publisher(.enableFullscreenMediaDetection, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                if change.newValue { self?.syncMonitoring() } else { self?.stopMonitoring() }
            }
            .store(in: &preferences)
        Defaults.publisher(.hideNotchOption, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                if change.newValue == .never { self?.stopMonitoring() } else { self?.syncMonitoring() }
            }
            .store(in: &preferences)
        syncMonitoring()
    }

    private var wantsMonitoring: Bool {
        Defaults[.enableFullscreenMediaDetection] && Defaults[.hideNotchOption] != .never
    }

    private func syncMonitoring() {
        guard wantsMonitoring else { stopMonitoring(); return }
        if observers.isEmpty {
            observe(NSWorkspace.activeSpaceDidChangeNotification, in: NSWorkspace.shared.notificationCenter)
            observe(NSApplication.didChangeScreenParametersNotification, in: .default)
        }
        scan?.cancel()
        scan = nil
        updateFullScreenStatus()
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter) {
        let token = generation
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScan(generation: token) }
        }
        observers.append((center, observer))
    }

    private func scheduleScan(generation token: UUID) {
        guard generation == token, wantsMonitoring else { return }
        scan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.wantsMonitoring else { return }
            self.scan = nil
            self.updateFullScreenStatus()
        }
        scan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func stopMonitoring() {
        generation = UUID()
        scan?.cancel()
        scan = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        if !fullscreenStatus.isEmpty { fullscreenStatus = [:] }
    }

    private func updateFullScreenStatus() {
        guard wantsMonitoring else { return }

        let apps = detector.detectFullscreenApps(debug: false)
        let names = NSScreen.screens.map { $0.localizedName }
        let hideOption = Defaults[.hideNotchOption]
        let playingBundleID = hideOption == .nowPlayingOnly ? MusicManager.shared.bundleIdentifier : nil

        var newStatus: [String: Bool] = [:]
        for name in names {
            newStatus[name] = apps.contains { app in
                guard app.screen.localizedName == name,
                      app.bundleIdentifier != "com.apple.finder" else { return false }

                // The notch stays on display by default (the window's collectionBehavior
                // rides along with fullscreen spaces). It only hides when the user's
                // "Hide DynamicIsland" option asks for it.
                switch hideOption {
                case .always:
                    // Hide for any app in genuine native fullscreen on this screen.
                    return isInNativeFullscreen(app)
                case .nowPlayingOnly:
                    // Hide only when the currently playing media app is in fullscreen.
                    return app.bundleIdentifier == playingBundleID
                        && isInNativeFullscreen(app)
                case .never:
                    // Always on display; never hide.
                    return false
                }
            }
        }

        if newStatus != fullscreenStatus {
            fullscreenStatus = newStatus
            NSLog("✅ Fullscreen status: \(newStatus)")
        }
    }

    /// Confirms an app the detector flagged as screen-filling is in *genuine* native
    /// fullscreen, not merely maximized/zoomed. On a notched Mac a maximized window and a
    /// fullscreen window report nearly identical frames, so frame size alone can't tell them
    /// apart — the Accessibility `AXFullScreen` attribute can. Falls back to the detector's
    /// frame-based result when Accessibility isn't trusted (so behavior doesn't silently break).
    private func isInNativeFullscreen(_ app: MacroVisionKit.FullscreenWindowInfo) -> Bool {
        guard AXIsProcessTrusted() else { return true }

        let appElement = AXUIElementCreateApplication(app.processId)

        // Prefer the focused window, then fall back to scanning all windows.
        if let focused: AXUIElement = copyAttribute(kAXFocusedWindowAttribute as CFString, from: appElement),
           isWindowFullscreen(focused) {
            return true
        }

        if let windows: [AXUIElement] = copyAttribute(kAXWindowsAttribute as CFString, from: appElement) {
            return windows.contains { isWindowFullscreen($0) }
        }

        return false
    }

    private func isWindowFullscreen(_ window: AXUIElement) -> Bool {
        // "AXFullScreen" is the (undocumented but stable) attribute set true only in native
        // fullscreen; maximized/zoomed windows report false or omit it.
        let value: Bool? = copyAttribute("AXFullScreen" as CFString, from: window)
        return value ?? false
    }

    private func copyAttribute<T>(_ attribute: CFString, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let typed = value as? T else { return nil }
        return typed
    }

}
