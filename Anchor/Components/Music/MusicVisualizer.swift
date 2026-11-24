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

import AppKit
import Cocoa
import SwiftUI
import Defaults

class AudioSpectrumVisibilityView: NSView {
    private var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var barColor: NSColor {
        Defaults[.coloredSpectrogram] ? SurfaceStyle.vivid(MusicManager.shared.avgColor) : .white
    }

    var isVisibleForAnimation: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
            && !isHiddenOrHasHiddenAncestor && !NSApp.isHidden
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in self?.refreshAnimationDemand()
                })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in self?.refreshAnimationDemand()
                })
            }
        }
        refreshAnimationDemand()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshAnimationDemand()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshAnimationDemand()
    }

    func refreshAnimationDemand() {}
}

class AudioSpectrum: AudioSpectrumVisibilityView {
    private var barLayers: [CAShapeLayer] = []
    private static let minimumScale: CGFloat = 0.2
    private var isPlaying = false
    private var lastBoundsSize = CGSize.zero
    private var appliedBarCount = 0
    private var appliedBarColor: NSColor?
    private var animationTimer: Timer?
    
    override func layout() {
        super.layout()
        refreshAppearance()
    }

    func refreshAppearance() {
        let barCount = min(128, max(1, Defaults[.visualizerBarCount]))
        let color = barColor
        guard bounds.size != lastBoundsSize || barCount != appliedBarCount || color != appliedBarColor else { return }
        lastBoundsSize = bounds.size
        appliedBarCount = barCount
        appliedBarColor = color

        wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers.removeAll(keepingCapacity: true)

        let slot = bounds.width / CGFloat(barCount)
        let barWidth = slot * 0.5
        for index in 0..<barCount {
            let bar = CAShapeLayer()
            bar.frame = CGRect(
                x: CGFloat(index) * slot + (slot - barWidth) / 2, y: 0,
                width: barWidth, height: bounds.height)
            bar.fillColor = color.cgColor
            bar.path = CGPath(roundedRect: bar.bounds, cornerWidth: barWidth / 2,
                              cornerHeight: barWidth / 2, transform: nil)
            bar.transform = CATransform3DMakeScale(1, Self.minimumScale, 1)
            barLayers.append(bar)
            layer?.addSublayer(bar)
        }
        CATransaction.commit()
    }

    deinit {
        animationTimer?.invalidate()
    }

    override func refreshAnimationDemand() {
        if isPlaying && isVisibleForAnimation {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateBars()
        }
        // The bars are randomised anyway; exact timing is meaningless here.
        timer.tolerance = 0.15
        animationTimer = timer
    }
    
    private func stopAnimating() {
        guard animationTimer != nil else { return }
        animationTimer?.invalidate()
        animationTimer = nil
        resetBars()
    }
    
    private func updateBars() {
        for barLayer in barLayers {
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = barLayer.presentation()?.value(forKeyPath: "transform.scale.y") ?? Self.minimumScale
            animation.toValue = CGFloat.random(in: Self.minimumScale ... 1)
            animation.duration = 0.3
            animation.autoreverses = true
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            if #available(macOS 13.0, *) {
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 24, preferred: 24)
            }
            barLayer.add(animation, forKey: "scaleY")
        }
    }
    
    private func resetBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for barLayer in barLayers {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, Self.minimumScale, 1)
        }
        CATransaction.commit()
    }
    
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        refreshAnimationDemand()
    }
}

struct AudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool
    @Default(.visualizerBarCount) private var barCount
    
    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        spectrum.setPlaying(isPlaying)
        return spectrum
    }
    
    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying)
        nsView.refreshAppearance()
    }

    static func dismantleNSView(_ nsView: AudioSpectrum, coordinator: ()) {
        nsView.setPlaying(false)
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
