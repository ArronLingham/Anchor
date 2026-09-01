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
import Foundation
import ScreenCaptureKit
import Vision

/// Captures the screen, and reads text out of what it captures.
///
/// This is the foundation several features sit on — screenshots, copy-text-
/// from-screen, and eventually window thumbnails — so it is deliberately a
/// service with no UI and no stored state rather than a manager.
///
/// ## Why ScreenCaptureKit rather than `CGWindowListCreateImage`
///
/// The `CGWindowList` capture functions are deprecated as of macOS 14 and
/// return blank images on recent releases unless the caller holds Screen
/// Recording. ScreenCaptureKit is the supported path, it reports permission
/// failures as real errors instead of silently handing back an empty image,
/// and it is what the system screenshot UI itself uses.
///
/// ## Permission
///
/// Everything here needs Screen Recording, which Anchor has never requested
/// before. The first call triggers the system prompt. A denial surfaces as
/// `CaptureError.notPermitted` rather than an empty result, because a blank
/// screenshot with no explanation is the worst possible failure.
///
/// ## Cost
///
/// None at rest. Nothing is retained between calls: each capture builds a
/// fresh `SCScreenshotManager` request and tears it down. There is no stream,
/// no timer and no observer, so an unused capture feature costs nothing.
enum ScreenCaptureService {
    enum CaptureError: LocalizedError {
        case notPermitted
        case noDisplay
        case captureFailed(String)
        case noTextFound

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                return "Anchor needs Screen Recording permission. Grant it in System Settings › Privacy & Security › Screen Recording, then try again."
            case .noDisplay:
                return "No display available to capture."
            case .captureFailed(let detail):
                return "Could not capture the screen: \(detail)"
            case .noTextFound:
                return "No readable text found."
            }
        }
    }

    // MARK: - Capture

    /// Captures a whole display.
    ///
    /// `display` defaults to the one holding the pointer, which is what the
    /// user means by "the screen" when they have more than one.
    static func captureDisplay(_ display: SCDisplay? = nil) async throws -> CGImage {
        let content = try await shareableContent()
        guard let target = display ?? displayUnderPointer(in: content) ?? content.displays.first
        else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: target, excludingWindows: [])
        let config = SCStreamConfiguration()
        // Capture at the display's true backing resolution — a Retina screen
        // captured at point size comes out soft, and OCR on a soft image is
        // markedly worse.
        config.width = target.width * scaleFactor(for: target)
        config.height = target.height * scaleFactor(for: target)
        config.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            throw mapped(error)
        }
    }

    /// Captures a rectangle in global (screen) coordinates.
    static func captureRegion(_ rect: CGRect) async throws -> CGImage {
        let content = try await shareableContent()
        guard let target = display(containing: rect, in: content) ?? content.displays.first
        else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: target, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = scaleFactor(for: target)

        // sourceRect is relative to the display's own origin, not global space.
        let local = CGRect(
            x: rect.origin.x - target.frame.origin.x,
            y: rect.origin.y - target.frame.origin.y,
            width: rect.width, height: rect.height)
        config.sourceRect = local
        config.width = Int(local.width) * scale
        config.height = Int(local.height) * scale
        config.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            throw mapped(error)
        }
    }

    // MARK: - Text recognition

    /// Reads the text in an image, offline.
    ///
    /// `.accurate` rather than `.fast`: this runs once on a user action, not in
    /// a loop, so the extra time is imperceptible and the accuracy difference
    /// on small on-screen type is not.
    static func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: CaptureError.captureFailed(error.localizedDescription))
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                guard !lines.isEmpty else {
                    continuation.resume(throwing: CaptureError.noTextFound)
                    return
                }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: CaptureError.captureFailed(error.localizedDescription))
            }
        }
    }

    /// Decodes any QR code in an image, so a code on screen can be read
    /// without reaching for a phone.
    static func detectQRCode(in image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, _ in
                let payload = (request.results as? [VNBarcodeObservation] ?? [])
                    .compactMap(\.payloadStringValue)
                    .first
                continuation.resume(returning: payload)
            }
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: - Output

    /// Writes a PNG to the clipboard.
    @MainActor
    static func copyToClipboard(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        ClipboardManager.shared.ignoreChangeCount(pasteboard.changeCount)
    }

    /// Saves a PNG and returns where it went.
    @discardableResult
    static func save(_ image: CGImage, to directory: URL? = nil) throws -> URL {
        let folder = directory
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder.appendingPathComponent("Anchor Screenshot \(formatter.string(from: Date())).png")

        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError.captureFailed("could not encode PNG")
        }
        try png.write(to: url)
        return url
    }

    // MARK: - Helpers

    private static func shareableContent() async throws -> SCShareableContent {
        do {
            // `excludingDesktopWindows: false` keeps wallpaper and desktop icons
            // in the shot, which is what a screenshot is expected to contain.
            return try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            throw mapped(error)
        }
    }

    /// ScreenCaptureKit reports a missing grant as a plain `SCStreamError`, so
    /// the code has to be matched to say something useful about it.
    private static func mapped(_ error: Error) -> CaptureError {
        let nsError = error as NSError
        // -3801 is SCStreamErrorUserDeclined; -3802 is "no permission".
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == -3801 || nsError.code == -3802 {
            return .notPermitted
        }
        return .captureFailed(error.localizedDescription)
    }

    private static func displayUnderPointer(in content: SCShareableContent) -> SCDisplay? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
        else { return nil }
        let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return content.displays.first { $0.displayID == displayID }
    }

    private static func display(containing rect: CGRect, in content: SCShareableContent) -> SCDisplay? {
        content.displays.first { $0.frame.intersects(rect) }
    }

    private static func scaleFactor(for display: SCDisplay) -> Int {
        let displayID = display.displayID
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                == displayID
        }
        return Int(screen?.backingScaleFactor ?? 2)
    }
}
