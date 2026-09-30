/*
 * Atoll (DynamicIsland)
 * Original work Copyright (C) 2026 ZephyrCodesStuff (https://github.com/ZephyrCodesStuff/rtaudio)
 * Modified work Copyright (C) 2026 Atoll Contributors
 *
 * Real-time audio spectrum visualization using CoreAudio tap data.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful,
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
import simd
import Defaults

/// NSView-based real-time audio spectrum visualizer
class RealTimeAudioSpectrum: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var isPlaying: Bool = true
    private var animationTimer: Timer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }

    deinit {
        stopAnimating()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    /// Rebuilt on every size change and whenever the bar count changes.
    ///
    /// It used to run exactly once, from `init`, and pin `frame.size` to a
    /// hardcoded 14pt height with bars laid out for that height. The element is
    /// placed with `.frame(maxWidth: .infinity, maxHeight: .infinity)`, so the
    /// layers had no relationship to the space actually given to them — the
    /// bars drew at the wrong size and in the wrong place, which is the
    /// "glitches out" half of the report. Changing `visualizerBarCount` did
    /// nothing at all, because nothing ever rebuilt them.
    private func setupBars() {
        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers.removeAll()

        let barCount = max(1, Defaults[.visualizerBarCount])
        let height = max(4, bounds.height)
        let width = max(CGFloat(barCount), bounds.width)
        // Half the slot is bar, half is gap — the proportion the fixed 2pt/2pt
        // version encoded, expressed against the space actually given to us.
        let slot = width / CGFloat(barCount)
        let barWidth = max(1, slot * 0.5)
        let colour = barColor.cgColor

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * slot + (slot - barWidth) / 2
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: height)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: height / 2)
            barLayer.fillColor = colour

            let path = NSBezierPath(
                roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: height),
                xRadius: barWidth / 2, yRadius: barWidth / 2)
            barLayer.path = path.cgPath

            barLayers.append(barLayer)
            layer?.addSublayer(barLayer)
        }
    }

    /// White, or the album's colour when `coloredSpectrogram` is on — which is
    /// what that setting has always claimed to do and never did. It gated
    /// album-colour EXTRACTION in `MusicManager` instead, so the one control
    /// named after the visualiser was the one thing it did not affect.
    private var barColor: NSColor {
        Defaults[.coloredSpectrogram]
            ? SurfaceStyle.vivid(MusicManager.shared.avgColor) : .white
    }

    private var lastLaidOutSize: CGSize = .zero

    override func layout() {
        super.layout()
        guard bounds.size != lastLaidOutSize else { return }
        lastLaidOutSize = bounds.size
        // Actions disabled: otherwise every resize animates each bar's implicit
        // position change and the spectrum visibly swells when the window moves
        // between displays. The same rule the record already follows.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setupBars()
        CATransaction.commit()
        appliedBarCount = max(1, Defaults[.visualizerBarCount])
        appliedColour = barColor
    }

    /// Rebuild only when the appearance actually changed.
    ///
    /// `updateNSView` runs on every SwiftUI update of the wrapper — including
    /// every play/pause, since `isPlaying` is a binding on it. Rebuilding every
    /// CAShapeLayer and NSBezierPath on each of those is pure waste: the guard
    /// turns a per-update teardown into one that fires only when the stepper or
    /// the toggle moves.
    private var appliedBarCount = 0
    private var appliedColour: NSColor?

    func refreshAppearance() {
        let wantedCount = max(1, Defaults[.visualizerBarCount])
        let wantedColour = barColor
        guard wantedCount != appliedBarCount || wantedColour != appliedColour else { return }
        appliedBarCount = wantedCount
        appliedColour = wantedColour
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setupBars()
        CATransaction.commit()
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimating()
        } else if isPlaying {
            startAnimating()
        }
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        // Tell AudioTap something is on screen; this is what starts the CoreAudio
        // process tap. Balanced by the release() in stopAnimating().
        AudioTap.shared.acquire()
        // Use a timer at ~30fps for smooth animation
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            self?.updateBarsFromAudio()
        }
        // Let the kernel coalesce these with other wakeups; a spectrum bar being
        // a few ms late is invisible.
        timer.tolerance = 1.0 / 120.0
        animationTimer = timer
    }
    
    private func stopAnimating() {
        guard animationTimer != nil else { return }
        animationTimer?.invalidate()
        animationTimer = nil
        AudioTap.shared.release()
        resetBars()
    }
    
    private var debugLogCounter = 0
    
    private func updateBarsFromAudio() {
        guard isPlaying else {
            resetBars()
            return
        }
        
        // Get real-time magnitudes from AudioTap
        let magnitudes = AudioTap.shared.getSmoothedMagnitudes()
        
        // Debug: log magnitudes periodically
        debugLogCounter += 1
        if debugLogCounter % 60 == 0 { // Every 2 seconds at 30fps
            if magnitudes.count >= 4 {
                print("📊 [Spectrum] Magnitudes: [\(magnitudes[0]), \(magnitudes[1]), \(magnitudes[2]), \(magnitudes[3])]")
            }
        }
        
        // Update each bar with its corresponding band magnitude
        for (index, barLayer) in barLayers.enumerated() {
            guard index < magnitudes.count else { break }
            let magnitude = magnitudes[index]
            // Map magnitude (0-1) to scale (0.2 - 1.0) for visual appeal
            let scale = max(0.2, min(1.0, CGFloat(magnitude) * 1.5 + 0.2))
            
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            barLayer.transform = CATransform3DMakeScale(1, scale, 1)
            CATransaction.commit()
        }
    }
    
    private func resetBars() {
        for barLayer in barLayers {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            barLayer.transform = CATransform3DMakeScale(1, 0.2, 1)
            CATransaction.commit()
        }
    }
    
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if isPlaying {
            startAnimating()
        } else {
            stopAnimating()
        }
    }
}

/// SwiftUI wrapper for RealTimeAudioSpectrum
struct RealTimeAudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool
    // Declared so SwiftUI re-runs `updateNSView` when they change. The AppKit
    // view reads `Defaults` itself; these exist to make the change observed.
    @Default(.visualizerBarCount) private var barCount
    @Default(.coloredSpectrogram) private var colouredBars
    
    func makeNSView(context: Context) -> RealTimeAudioSpectrum {
        let spectrum = RealTimeAudioSpectrum()
        spectrum.setPlaying(isPlaying)
        return spectrum
    }
    
    func updateNSView(_ nsView: RealTimeAudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying)
        // The bar count and the colour are observed by the SwiftUI wrapper, so
        // a change re-runs this; the view rebuilds its layers from it. Without
        // this the stepper moved and nothing on screen changed.
        nsView.refreshAppearance()
    }

    static func dismantleNSView(_ nsView: RealTimeAudioSpectrum, coordinator: ()) {
        nsView.setPlaying(false)
    }
}

#Preview {
    RealTimeAudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
