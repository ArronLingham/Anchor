#if ANCHOR_UTILITIES_DEVELOPMENT
import AppKit
import AVFoundation
import SwiftUI

/// Development-only visual checks use generated media and offscreen windows.
/// They never move the real pointer, record the display, or lock the session.
public enum UtilityReview {
    @MainActor public static func render(into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = UtilityWorkspace.shared
        let defaults = UtilityPreferences.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = Defaults.registeredDefaults
        for feature in AppFeature.allCases {
            arguments[feature.availabilityKey] = true
            for key in feature.enabledKeys { arguments[key] = false }
        }
        for key in arguments.keys where key.hasSuffix("Enabled") || key == DefaultsKey.hotkeyEnabled {
            if arguments[key] is Bool { arguments[key] = false }
        }
        arguments[DefaultsKey.cleanerScheduleFrequency] = "off"
        arguments[DefaultsKey.appUpdatesCheckFrequency] = "off"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        SettingsWindowVisibility.shared.set(true)
        defer {
            SettingsWindowVisibility.shared.set(false)
            defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain)
        }

        var captured: [String] = []
        let pages: [(String, SettingsPage)] = [
            ("features", .features), ("general", .general), ("energy", .energy),
            ("monitor", .monitor), ("mouse", .mouse), ("switcher", .switcher),
            ("dock", .dock), ("window-layout", .windowLayout), ("auto-quit", .autoQuit),
            ("quit-protection", .quitProtection), ("clipboard", .clipboard),
            ("finder", .cutPaste), ("shelf", .shelf), ("media", .media),
            ("tools", .quickTools), ("url-cleaner", .urlCleaner),
            ("cleanup", .cleaner), ("homebrew", .homebrew), ("app-updates", .appUpdates),
            ("uninstaller", .uninstaller), ("processes", .killProcess), ("ports", .portManager),
            ("key-debounce", .keyDebounce), ("super-key", .superKey),
            ("snippets", .textSnippets), ("screen-capture", .screenshot),
            ("action-wheel", .radialMenu), ("command-bar", .commandBar),
            ("island", .notch), ("companion", .notchMascot),
            ("shortcuts", .shortcuts), ("backup", .advanced),
        ]
        for (name, page) in pages {
            SettingsRouter.shared.page = page
            try await capture(SettingsView(), named: name, size: CGSize(width: 1130, height: 760), into: directory)
            captured.append(name)
        }
        try await capture(UtilityLibraryView(), named: "library", size: CGSize(width: 900, height: 760), into: directory)
        try await capture(UtilityFavoritesView().padding(24), named: "favorites", size: CGSize(width: 460, height: 260), into: directory)
        captured += ["library", "favorites"]

        let image = try sampleImage()
        let preview = ScreenshotSelectionController.Capture(image: image, scale: 1,
                                                            anchorRect: CGRect(x: 200, y: 200, width: 640, height: 360))
        let editor = ScreenshotEditorController(capture: preview)
        try await capture(editor.reviewContentView(),
                          named: "screenshot-editor", size: CGSize(width: 1130, height: 760), into: directory)
        captured.append("screenshot-editor")
        let fixture = directory.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let take = RecorderTakeStore.Take(id: UUID(), folder: fixture)
        try await writeMovie(to: take.videoURL, image: image)
        let recorder = RecorderEditorController(take: take)
        try await capture(recorder.reviewContentView(),
                          named: "recording-editor", size: CGSize(width: 1130, height: 760), into: directory)
        captured.append("recording-editor")
        try await capture(MediaWorkspaceView(compact: false), named: "media-workspace",
                          size: CGSize(width: 1050, height: 720), into: directory)
        captured.append("media-workspace")
        let result: [String: Any] = ["rendered": captured, "featureCount": AppFeature.allCases.count,
                                     "pointerMoved": false, "realScreenCapture": false,
                                     "lockInvoked": false, "syntheticMovie": take.videoURL.path]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("review.json"), options: .atomic)
    }

    @MainActor private static func capture<V: View>(_ view: V, named name: String,
                                                   size: CGSize, into directory: URL) async throws {
        let host = NSHostingView(rootView: view.defaultAppStorage(UtilityPreferences.standard))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.backgroundColor = .windowBackgroundColor
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.coderInvalidValue)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }

    private static func sampleImage() throws -> CGImage {
        guard let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
                                      bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.coderInvalidValue)
        }
        context.setFillColor(CGColor(red: 0.10, green: 0.16, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        for index in 0..<8 {
            context.setFillColor(CGColor(red: CGFloat(index) / 10 + 0.15, green: 0.65,
                                         blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 35 + index * 72, y: 50, width: 50, height: 50 + index * 25))
        }
        guard let image = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
        return image
    }

    private static func writeMovie(to url: URL, image: CGImage) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                         kCVPixelBufferWidthKey as String: 640,
                                         kCVPixelBufferHeightKey as String: 360])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<8 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                if Date() > deadline { throw CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(10))
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32ARGB,
                [kCVPixelBufferCGImageCompatibilityKey: true,
                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw CocoaError(.coderInvalidValue) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 360,
                                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: 640, height: 360))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 8)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
#endif
