/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
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

#if os(macOS)
import AppKit
import SwiftUI
import SkyLightWindow
import QuartzCore
import Defaults
import Combine

@MainActor
final class CircularHUDWindowManager {
    static let shared = CircularHUDWindowManager()
    
    private var windows: [NSScreen: OSDWindow] = [:]
    private var screenObserver: NSObjectProtocol?
    private var visibilityGeneration = UUID()
    private var hideWorkItem: DispatchWorkItem?
    private let displayDuration: TimeInterval = 2.0
    private let animationDuration: TimeInterval = 0.2
    
    private var cancellables = Set<AnyCancellable>()
    
    // Layout constants removed in favor of dynamic calculation
    
    private init() {
        setupSizeObserver()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconcileScreens() }
        }
    }
    
    private func setupSizeObserver() {
        Defaults.publisher(.circularHUDSize, options: []).sink { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.updateWindowLayout()
            }
        }.store(in: &cancellables)
    }
    
    private func reconcileScreens() {
        let connected = Set(NSScreen.screens)
        for screen in Array(windows.keys) where !connected.contains(screen) {
            windows.removeValue(forKey: screen)?.nsWindow.orderOut(nil)
        }
        updateWindowLayout()
    }

    private func updateWindowLayout() {
        let layout = CircularHUDLayout(diameter: Defaults[.circularHUDSize])
        for (screen, window) in windows {
            window.nsWindow.setFrame(layout.frame(in: screen.visibleFrame), display: true)
            window.hostingView.frame = NSRect(origin: .zero, size: window.nsWindow.contentLayoutRect.size)
        }
    }

    func show(type: SneakContentType, value: CGFloat, icon: String = "", onScreen targetScreen: NSScreen? = nil, isPreview: Bool = false) {
        guard Defaults[.enableCircularHUD] else { return }
        
        // No explicit screen means the caller has no opinion, so the user's
        // placement setting decides. Volume used to land on every display at
        // once, which is noise on a multi-monitor desk.
        let resolved = targetScreen ?? Defaults[.hudDisplayPlacement].resolvedScreen
        let screens = resolved.map { [$0] } ?? NSScreen.screens
        guard !screens.isEmpty else { return }
        
        visibilityGeneration = UUID()
        // A change of the active display must not leave the previous HUD visible.
        for (screen, window) in windows where !screens.contains(screen) { window.nsWindow.orderOut(nil) }
        updateWindowLayout()
        // Show on target screen(s)
        for screen in screens {
            let windowContext = ensureWindow(for: type, screen: screen)
            updateContent(window: windowContext, type: type, value: value, icon: icon, screen: screen, isPreview: isPreview)
            
            // Ensure visible
            windowContext.nsWindow.orderFrontRegardless()
            
            windowContext.nsWindow.alphaValue = 1
        }
        
        scheduleHide()
    }
    
    private func ensureWindow(for type: SneakContentType, screen: NSScreen) -> OSDWindow {
        if let existing = windows[screen] {
            return existing
        }
        
        let osdView = CircularHUDView(type: .constant(type), value: .constant(0), icon: .constant(""))
        let hostingView = NSHostingView(rootView: osdView)
        
        let layout = CircularHUDLayout(diameter: Defaults[.circularHUDSize])
        let frame = layout.frame(in: screen.visibleFrame)
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = NSRect(origin: .zero, size: frame.size)

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.hasShadow = false
        win.contentView = hostingView
        win.alphaValue = 0
        
        SkyLightOperator.shared.delegateWindow(win)
        
        let windowStruct = OSDWindow(nsWindow: win, hostingView: hostingView, type: type)
        windows[screen] = windowStruct
        return windowStruct
    }
    
    private func updateContent(window: OSDWindow, type: SneakContentType, value: CGFloat, icon: String, screen: NSScreen, isPreview: Bool) {
        let osdView = CircularHUDView(type: .constant(type), value: .constant(CircularHUDLayout.normalized(value)), icon: .constant(icon), screen: screen, isPreview: isPreview)
        window.hostingView.rootView = osdView
    }
    
    private func scheduleHide() {
        hideWorkItem?.cancel()
        
        let generation = visibilityGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.visibilityGeneration == generation else { return }
                self.hideWindow()
            }
        }
        
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration, execute: workItem)
    }
    
    private func hideWindow() {
        for window in windows.values {
            window.nsWindow.alphaValue = 0
            window.nsWindow.orderOut(nil)
        }
    }

    // Helper struct
    private struct OSDWindow {
        let nsWindow: NSWindow
        let hostingView: NSHostingView<CircularHUDView>
        let type: SneakContentType
    }
}
#endif
