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

import AppKit
import QuartzCore

/// The spinning record itself, drawn in CALayers.
///
/// **Deliberately not SwiftUI.** A record turns continuously for as long as
/// music plays, and a SwiftUI rotation is a per-frame transaction on the main
/// thread — the exact shape this project spent a release removing. A
/// `CABasicAnimation` is handed to the render server once and costs this
/// process nothing per frame, which is the same reasoning behind the spectrum
/// visualiser being a plain NSView.
///
/// The animation is added when playback starts and removed when it stops, so a
/// paused record is a static image with no timer, no transaction and no
/// redraw behind it.
final class VinylRecordView: NSView {
    /// 33⅓ rpm, the speed an LP actually turns at. Slowed by `speedFactor`
    /// because a real 1.8 s revolution reads as frantic at widget size.
    private static let revolutionsPerMinute = 33.333
    private static let speedFactor = 2.5

    private let discLayer = CALayer()
    private let grooveLayer = CAShapeLayer()
    private let artworkLayer = CALayer()
    private let labelRingLayer = CAShapeLayer()
    private let spindleLayer = CAShapeLayer()
    private let rotatingLayer = CALayer()
    private let artworkMaskLayer = CAShapeLayer()

    private var isSpinning = false

    /// Fraction of the disc taken by the paper label in the middle.
    var labelFraction: CGFloat = 0.38 { didSet { needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        buildLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Construction

    private func buildLayers() {
        guard let root = layer else { return }

        // Everything that turns lives on one layer, so a single rotation
        // animation moves the vinyl, its grooves and the label together.
        rotatingLayer.addSublayer(discLayer)
        rotatingLayer.addSublayer(grooveLayer)
        rotatingLayer.addSublayer(artworkLayer)
        rotatingLayer.addSublayer(labelRingLayer)
        root.addSublayer(rotatingLayer)
        // The spindle is the axis; it must not turn with the record.
        root.addSublayer(spindleLayer)

        discLayer.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
        discLayer.shadowColor = NSColor.black.cgColor
        discLayer.shadowOpacity = 0.45
        discLayer.shadowRadius = 12
        discLayer.shadowOffset = CGSize(width: 0, height: -3)

        grooveLayer.fillColor = nil
        grooveLayer.strokeColor = NSColor(calibratedWhite: 0.30, alpha: 0.30).cgColor
        grooveLayer.lineWidth = 0.5

        artworkLayer.contentsGravity = .resizeAspectFill
        artworkLayer.masksToBounds = true
        // An explicit shape mask rather than cornerRadius alone. `contents` set
        // from an NSImage is not reliably clipped by a corner radius, and a
        // square album cover sitting on a round record is the one thing that
        // would give the whole illusion away.
        artworkLayer.mask = artworkMaskLayer

        labelRingLayer.fillColor = nil
        labelRingLayer.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        labelRingLayer.lineWidth = 1

        spindleLayer.fillColor = NSColor(calibratedWhite: 0.75, alpha: 1).cgColor
        spindleLayer.strokeColor = NSColor(calibratedWhite: 0.2, alpha: 1).cgColor
        spindleLayer.lineWidth = 0.5
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)

        // Layout must not be animated: an implicit animation here makes the
        // record visibly swell every time the window is resized or moved
        // between displays.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        rotatingLayer.frame = bounds
        rotatingLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        rotatingLayer.position = centre
        rotatingLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)

        let local = CGRect(x: 0, y: 0, width: side, height: side)
        discLayer.frame = local
        discLayer.cornerRadius = side / 2

        grooveLayer.frame = local
        grooveLayer.path = groovePath(in: local)

        let labelSide = side * labelFraction
        artworkLayer.frame = CGRect(
            x: (side - labelSide) / 2, y: (side - labelSide) / 2,
            width: labelSide, height: labelSide)
        artworkLayer.cornerRadius = labelSide / 2
        artworkMaskLayer.frame = CGRect(x: 0, y: 0, width: labelSide, height: labelSide)
        artworkMaskLayer.path = CGPath(
            ellipseIn: artworkMaskLayer.frame, transform: nil)
        artworkMaskLayer.fillColor = NSColor.black.cgColor

        labelRingLayer.frame = local
        labelRingLayer.path = CGPath(
            ellipseIn: artworkLayer.frame.insetBy(dx: -1, dy: -1), transform: nil)

        let spindle = max(4, side * 0.035)
        spindleLayer.frame = bounds
        spindleLayer.path = CGPath(
            ellipseIn: CGRect(
                x: centre.x - spindle / 2, y: centre.y - spindle / 2,
                width: spindle, height: spindle),
            transform: nil)
    }

    /// Concentric grooves. Twenty-two rings reads as vinyl without turning into
    /// a moiré pattern at small sizes.
    private func groovePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let outer = rect.width / 2 - 2
        let inner = rect.width * labelFraction / 2 + 3
        guard outer > inner else { return path }

        let count = 22
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1)
            let radius = inner + (outer - inner) * t
            path.addEllipse(in: CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2))
        }
        return path
    }

    // MARK: - Content

    /// Sets the label art.
    ///
    /// Converted to a `CGImage` rather than handed the `NSImage` directly.
    /// `CALayer.contents` accepts an `NSImage`, but with one it does not honour
    /// `contentsGravity` or clip to the layer's corner radius — a square album
    /// cover then sits on top of a round record, which gives the whole illusion
    /// away. A `CGImage` behaves.
    func setArtwork(_ image: NSImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let image else {
            artworkLayer.contents = nil
            return
        }
        var rect = CGRect(origin: .zero, size: image.size)
        artworkLayer.contents = image.cgImage(
            forProposedRect: &rect, context: nil, hints: nil)
        artworkLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    // MARK: - Spin

    /// Starts or stops the rotation.
    ///
    /// Resuming preserves the angle the record stopped at rather than snapping
    /// back to zero, which is what makes a pause look like a pause rather than
    /// a reset.
    func setSpinning(_ spinning: Bool) {
        guard spinning != isSpinning else { return }
        isSpinning = spinning
        spinning ? startSpin() : stopSpin()
    }

    private func startSpin() {
        let duration = 60.0 / (Self.revolutionsPerMinute / Self.speedFactor)

        let current = rotatingLayer.presentation()?
            .value(forKeyPath: "transform.rotation.z") as? Double ?? 0

        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = current
        animation.toValue = current - (2 * Double.pi)   // clockwise on screen
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotatingLayer.add(animation, forKey: "spin")
    }

    private func stopSpin() {
        let angle = rotatingLayer.presentation()?
            .value(forKeyPath: "transform.rotation.z") as? Double ?? 0
        rotatingLayer.removeAnimation(forKey: "spin")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotatingLayer.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
    }
}
