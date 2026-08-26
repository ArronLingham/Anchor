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
import SwiftUI

/// Draws the capture session.
///
/// A plain `AVCaptureVideoPreviewLayer` in an `NSView`: the compositor moves
/// the frames, so no frame ever crosses into SwiftUI and nothing re-renders per
/// frame. Routing video through SwiftUI state would be the waveform mistake at
/// thirty times the data.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer = preview
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let layer = nsView.layer as? AVCaptureVideoPreviewLayer,
              layer.session !== session
        else { return }
        layer.session = session
    }
}

/// Camera mirror.
struct NotchCameraMirrorView: View {
    @ObservedObject private var manager = CameraMirrorManager.shared

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Reference-counted: the capture session exists only while this is
            // on screen, and the green privacy light with it.
            .onAppear { manager.acquire() }
            .onDisappear { manager.release() }
    }

    @ViewBuilder
    private var content: some View {
        switch manager.state {
        case .running:
            if let session = manager.session {
                CameraPreview(session: session)
                    // Mirrored, because a mirror is what people expect when
                    // looking at themselves.
                    .scaleEffect(x: -1, y: 1)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                message("Starting…")
            }
        case .denied:
            message("Camera access denied. Grant it in System Settings → Privacy & Security → Camera.")
        case .unavailable:
            message("No camera available.")
        case .idle:
            message("Camera off.")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
