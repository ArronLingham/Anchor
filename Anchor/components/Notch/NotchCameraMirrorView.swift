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

import AVFoundation
import AppKit
import Defaults
import SwiftUI

/// Hosts the capture preview layer.
///
/// An `NSViewRepresentable` rather than anything SwiftUI-native, because
/// `AVCaptureVideoPreviewLayer` is a CALayer the render server drives directly
/// — no per-frame SwiftUI transaction, which is the cost the vinyl widget and
/// the waveform both had to avoid.
private class CameraHostView: NSView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            guard oldValue !== previewLayer else { return }
            oldValue?.removeFromSuperlayer()
            if let previewLayer {
                layer?.addSublayer(previewLayer)
                needsLayout = true
            }
        }
    }

    override func layout() {
        super.layout()
        guard let preview = previewLayer, let host = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = host.bounds
        CATransaction.commit()
    }
}

private struct CameraPreview: NSViewRepresentable {
    @Default(.cameraMirrorFlipped) private var flipped

    func makeNSView(context: Context) -> CameraHostView {
        let view = CameraHostView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ view: CameraHostView, context: Context) {
        view.previewLayer = CameraMirrorManager.shared.previewLayer
        
        if let preview = view.previewLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.setAffineTransform(flipped ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
            CATransaction.commit()
        }
    }
}

/// The camera mirror tab in the open notch.
struct NotchCameraMirrorView: View {
    @ObservedObject private var manager = CameraMirrorManager.shared

    var body: some View {
        ZStack {
            if let failure = manager.failure {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text(failure)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
            } else {
                CameraPreview()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if !manager.isRunning {
                    ProgressView().controlSize(.small)
                }
            }
        }
        // The camera starts when this view appears and stops when it goes
        // away. Nothing holds it open in the background — the green indicator
        // is lit exactly as long as the preview is visible, which is the only
        // honest behaviour for a camera feature.
        .onAppear { manager.startSession() }
        .onDisappear { manager.stopSession() }
    }
}
