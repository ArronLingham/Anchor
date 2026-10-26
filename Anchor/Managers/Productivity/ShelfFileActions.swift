import AppKit
import Combine
import Foundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers
import Vision

@MainActor
final class ShelfFileActions: NSObject, ObservableObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ShelfFileActions()
    @Published private(set) var isWorking = false
    @Published var message: String?
    private var previewURLs: [URL] = []
    private var previewAccess: [URL] = []

    enum Action: String, CaseIterable, Identifiable {
        case zip = "Create ZIP archive…"
        case pdf = "Combine as PDF…"
        case png = "Convert images to PNG…"
        case jpeg = "Convert images to JPEG…"
        case resize = "Resize images to 1600 px…"
        case ocr = "Copy text from images"
        var id: String { rawValue }
    }
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }

    func preview(_ urls: [URL]) {
        releasePreviewAccess()
        previewURLs = urls
        previewAccess = urls.filter { $0.startAccessingSecurityScopedResource() }
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.delegate = self
        panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index] as NSURL
    }
    func windowWillClose(_ notification: Notification) { releasePreviewAccess(); previewURLs = [] }
    private func releasePreviewAccess() {
        previewAccess.forEach { $0.stopAccessingSecurityScopedResource() }; previewAccess = []
    }

    func available(_ action: Action, urls: [URL]) -> Bool {
        guard !urls.isEmpty, !isWorking else { return false }
        if action == .zip { return true }
        return urls.allSatisfy { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image) || (action == .pdf && type.conforms(to: .pdf))
        }
    }

    func perform(_ action: Action, urls: [URL]) {
        guard available(action, urls: urls) else { return }
        let destination: URL?
        if action == .ocr { destination = nil }
        else if action == .zip || action == .pdf {
            let panel = NSSavePanel()
            panel.allowedContentTypes = action == .zip ? [.zip] : [.pdf]
            panel.nameFieldStringValue = action == .zip ? "Shelf Archive.zip" : "Shelf Document.pdf"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard !urls.contains(where: { $0.standardizedFileURL == url.standardizedFileURL ||
                (action == .zip && url.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/")) }) else {
                message = "Choose a destination outside the source files or folders."; return
            }
            destination = url
        } else {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.canCreateDirectories = true; panel.prompt = "Save images here"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        isWorking = true; message = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.run(action, urls: urls, destination: destination)
                }.value
                if let text = result.text {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    ClipboardManager.shared.ignoreChangeCount(NSPasteboard.general.changeCount)
                    message = "Copied \(text.count) characters."
                } else {
                    ShelfManager.shared.add(urls: result.files)
                    message = "Saved \(result.files.count) \(result.files.count == 1 ? "file" : "files") to the shelf."
                }
            } catch { message = error.localizedDescription }
            isWorking = false
        }
    }

    struct Result: Sendable { var files: [URL] = []; var text: String? }

    nonisolated static func run(_ action: Action, urls: [URL], destination: URL?) throws -> Result {
        let access = urls.filter { $0.startAccessingSecurityScopedResource() }
        let destinationAccess = destination?.startAccessingSecurityScopedResource() ?? false
        defer {
            access.forEach { $0.stopAccessingSecurityScopedResource() }
            if destinationAccess { destination?.stopAccessingSecurityScopedResource() }
        }
        switch action {
        case .ocr:
            var texts: [String] = []
            for url in urls {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                try VNImageRequestHandler(url: url).perform([request])
                texts.append((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
            }
            let text = texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
            guard !text.isEmpty else { throw Failure.invalid("No readable text was found in these images.") }
            return Result(text: text)
        case .pdf:
            guard let destination else { throw Failure.invalid("Choose a destination.") }
            let document = PDFDocument()
            for url in urls {
                if url.pathExtension.lowercased() == "pdf" {
                    guard let source = PDFDocument(url: url), !source.isLocked else { throw Failure.invalid("Cannot read \(url.lastPathComponent). Unlock password-protected PDFs first.") }
                    for index in 0..<source.pageCount {
                        if let page = source.page(at: index)?.copy() as? PDFPage { document.insert(page, at: document.pageCount) }
                    }
                } else {
                    guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { throw Failure.invalid("Cannot read \(url.lastPathComponent).") }
                    document.insert(page, at: document.pageCount)
                }
            }
            guard document.pageCount > 0, let data = document.dataRepresentation() else { throw Failure.invalid("No PDF pages could be created.") }
            try data.write(to: destination, options: .atomic)
            return Result(files: [destination])
        case .zip:
            guard let destination else { throw Failure.invalid("Choose a destination.") }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("AnchorArchive-" + UUID().uuidString)
            let inputs = temp.appendingPathComponent("Items")
            try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            for url in urls {
                let link = uniqueURL(in: inputs, stem: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            }
            let archive = temp.appendingPathComponent("Archive.zip")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = inputs
            process.arguments = ["-r", "-q", archive.path, "."]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.invalid("The ZIP archive could not be created. Check that all files are available.") }
            let temporaryOutput = destination.deletingLastPathComponent().appendingPathComponent(".Anchor-" + UUID().uuidString + ".zip")
            defer { try? FileManager.default.removeItem(at: temporaryOutput) }
            try FileManager.default.copyItem(at: archive, to: temporaryOutput)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryOutput)
            } else { try FileManager.default.moveItem(at: temporaryOutput, to: destination) }
            return Result(files: [destination])
        case .png, .jpeg, .resize:
            guard let destination else { throw Failure.invalid("Choose a destination.") }
            var created: [URL] = []
            do {
                for url in urls {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Failure.invalid("Cannot read \(url.lastPathComponent).") }
                    let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                    let width = (metadata?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                    let height = (metadata?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
                    let fullEdge = max(width, height)
                    guard fullEdge > 0 else { throw Failure.invalid("Cannot read image dimensions.") }
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: action == .resize ? min(1600, fullEdge) : fullEdge
                    ]
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.invalid("Cannot convert \(url.lastPathComponent).") }
                    let jpeg = action == .jpeg
                    let output = uniqueURL(in: destination, stem: url.deletingPathExtension().lastPathComponent + (action == .resize ? "-1600" : "-converted"), ext: jpeg ? "jpg" : "png")
                    let data = NSMutableData()
                    guard let writer = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil) else { throw Failure.invalid("Image encoding is unavailable.") }
                    CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                    guard CGImageDestinationFinalize(writer) else { throw Failure.invalid("Could not encode \(url.lastPathComponent).") }
                    try (data as Data).write(to: output, options: .withoutOverwriting)
                    created.append(output)
                }
            } catch {
                created.forEach { try? FileManager.default.removeItem(at: $0) }
                throw error
            }
            return Result(files: created)
        }
    }

    nonisolated static func uniqueURL(in directory: URL, stem: String, ext: String) -> URL {
        var suffix = 1
        while true {
            let name = stem + (suffix == 1 ? "" : "-\(suffix)") + (ext.isEmpty ? "" : "." + ext)
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }
}
