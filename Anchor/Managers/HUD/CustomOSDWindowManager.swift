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

/// Manages custom OSD windows for volume, brightness, and keyboard backlight controls
/// Mimics macOS native OSD behavior with custom styling
@MainActor
final class CustomOSDWindowManager {
    static let shared = CustomOSDWindowManager()
    
    private var volumeWindows: [NSScreen: OSDWindow] = [:]
    private var brightnessWindows: [NSScreen: OSDWindow] = [:]
    private var contrastWindows: [NSScreen: OSDWindow] = [:]
    private var backlightWindows: [NSScreen: OSDWindow] = [:]
    
    private var hideWorkItem: DispatchWorkItem?
    private var hideGeneration = UUID()
    private let displayDuration: TimeInterval = 2.0
    private let animationDuration: TimeInterval = 0.3
    
    // Standard macOS OSD dimensions (approximate)
    private let osdWidth: CGFloat = 200
    private let osdHeight: CGFloat = 200
    
    private init() {}
    
    // MARK: - Public API
    
    func show(type: SneakContentType, value: CGFloat, icon: String = "", onScreen targetScreen: NSScreen? = nil) {
        guard Defaults[.enableCustomOSD] else { return }
        performShow(type: type, value: value, icon: icon, onScreen: targetScreen)
    }

    // MARK: - Private Implementation
    
    private func performShow(type: SneakContentType, value: CGFloat, icon: String, onScreen targetScreen: NSScreen? = nil) {
        let screens = targetScreen.map { [$0] } ?? NSScreen.screens
        guard !screens.isEmpty else { return }
        
        // Close other windows first
        closeOtherWindows(except: type)
        
        // Show on target screen(s)
        for screen in screens {
            let windowContext = ensureWindow(for: type, screen: screen)
            updateContent(window: windowContext, type: type, value: value, icon: icon)
            
            // Ensure visible
            windowContext.nsWindow.orderFrontRegardless()
            
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animationDuration
                windowContext.nsWindow.animator().alphaValue = 1
            }
        }
        
        scheduleHide(for: type)
    }
    
    private func ensureWindow(for type: SneakContentType, screen: NSScreen) -> OSDWindow {
        switch type {
        case .volume:
            if let existing = volumeWindows[screen] {
                return existing
            }
            let window = createWindow(for: type, screen: screen)
            volumeWindows[screen] = window
            return window
        case .brightness:
            if let existing = brightnessWindows[screen] {
                return existing
            }
            let window = createWindow(for: type, screen: screen)
            brightnessWindows[screen] = window
            return window
        case .contrast:
            if let existing = contrastWindows[screen] {
                return existing
            }
            let window = createWindow(for: type, screen: screen)
            contrastWindows[screen] = window
            return window
        case .backlight:
            if let existing = backlightWindows[screen] {
                return existing
            }
            let window = createWindow(for: type, screen: screen)
            backlightWindows[screen] = window
            return window
        default:
            fatalError("Unsupported OSD type: \(type)")
        }
    }
    
    private func createWindow(for type: SneakContentType, screen: NSScreen) -> OSDWindow {
        let osdView = CustomOSDView(type: .constant(type), value: .constant(0), icon: .constant(""))
        let hostingView = NSHostingView(rootView: osdView)
        
        let frame = calculateFrame(for: screen)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar + 1
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.hasShadow = false
        window.contentView = hostingView
        window.alphaValue = 0
        
        // Delegate to SkyLight for proper rendering
        SkyLightOperator.shared.delegateWindow(window)
        
        return OSDWindow(nsWindow: window, hostingView: hostingView, type: type)
    }
    
    private func updateContent(window: OSDWindow, type: SneakContentType, value: CGFloat, icon: String) {
        let osdView = CustomOSDView(type: .constant(type), value: .constant(value), icon: .constant(icon))
        window.hostingView.rootView = osdView
    }
    
    private func calculateFrame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        let centerX = screenFrame.midX - (osdWidth / 2)
        // Position at bottom center, similar to native macOS OSD
        let bottomOffset: CGFloat = 120 // Distance from bottom of screen
        let centerY = screenFrame.minY + bottomOffset
        
        return NSRect(x: centerX, y: centerY, width: osdWidth, height: osdHeight)
    }
    
    private func presentWindow(_ window: OSDWindow, targetFrame: NSRect) {
        let startFrame = targetFrame.offsetBy(dx: 0, dy: -20)
        window.nsWindow.setFrame(startFrame, display: true)
        window.nsWindow.alphaValue = 0
        window.nsWindow.orderFrontRegardless()
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.nsWindow.animator().setFrame(targetFrame, display: true)
            window.nsWindow.animator().alphaValue = 1
        }
    }
    
    private func closeOtherWindows(except type: SneakContentType) {
        if type != .volume {
            for window in volumeWindows.values where window.nsWindow.alphaValue > 0.01 {
                hideWindowImmediately(window)
            }
        }
        if type != .brightness {
            for window in brightnessWindows.values where window.nsWindow.alphaValue > 0.01 {
                hideWindowImmediately(window)
            }
        }
        if type != .contrast {
            for window in contrastWindows.values where window.nsWindow.alphaValue > 0.01 {
                hideWindowImmediately(window)
            }
        }
        if type != .backlight {
            for window in backlightWindows.values where window.nsWindow.alphaValue > 0.01 {
                hideWindowImmediately(window)
            }
        }
    }
    
    private func hideWindowImmediately(_ window: OSDWindow) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.nsWindow.animator().alphaValue = 0
        } completionHandler: {
            window.nsWindow.orderOut(nil)
        }
    }
    
    private func scheduleHide(for type: SneakContentType) {
        hideWorkItem?.cancel()
        let generation = UUID()
        hideGeneration = generation

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hideGeneration == generation else { return }
                self.hideWindow(for: type)
            }
        }
        
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration, execute: workItem)
    }
    
    private func hideWindow(for type: SneakContentType) {
        let windows: [OSDWindow]
        
        switch type {
        case .volume:
            windows = Array(volumeWindows.values)
        case .brightness:
            windows = Array(brightnessWindows.values)
        case .contrast:
            windows = Array(contrastWindows.values)
        case .backlight:
            windows = Array(backlightWindows.values)
        default:
            return
        }
        
        for window in windows {
        
        let currentFrame = window.nsWindow.frame
        let hideFrame = currentFrame.offsetBy(dx: 0, dy: -20)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.nsWindow.animator().setFrame(hideFrame, display: true)
            window.nsWindow.animator().alphaValue = 0
        } completionHandler: {
            // A newer show may reuse this window while the old fade finishes.
            if window.nsWindow.alphaValue == 0 { window.nsWindow.orderOut(nil) }
        }
        }
    }
    
    // MARK: - Cleanup
    
    func dismiss(_ controls: HUDControls) {
        if controls.contains(.volume) {
            volumeWindows.values.forEach { $0.nsWindow.orderOut(nil) }
            volumeWindows.removeAll()
        }
        if controls.contains(.brightness) {
            brightnessWindows.values.forEach { $0.nsWindow.orderOut(nil) }
            contrastWindows.values.forEach { $0.nsWindow.orderOut(nil) }
            brightnessWindows.removeAll()
            contrastWindows.removeAll()
        }
        if controls.contains(.backlight) {
            backlightWindows.values.forEach { $0.nsWindow.orderOut(nil) }
            backlightWindows.removeAll()
        }
        if volumeWindows.isEmpty, brightnessWindows.isEmpty, contrastWindows.isEmpty, backlightWindows.isEmpty {
            hideGeneration = UUID()
            hideWorkItem?.cancel()
            hideWorkItem = nil
        }
    }
}

// MARK: - OSD Window Container

private struct OSDWindow {
    let nsWindow: NSWindow
    let hostingView: NSHostingView<CustomOSDView>
    let type: SneakContentType
}

#endif
