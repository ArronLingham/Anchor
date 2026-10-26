import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

@MainActor final class ShelfManager { static let shared = ShelfManager(); func add(urls: [URL]) {} }
final class ClipboardManager { static let shared = ClipboardManager(); func ignoreChangeCount(_ count: Int) {} }

@main
struct ShelfFileActionTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
        checks += 1
        guard value() else { throw ShelfFileActions.Failure.invalid("FAIL: " + label) }
    }

    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnchorFileActionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outputs = root.appendingPathComponent("Outputs")
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        let imageURL = root.appendingPathComponent("Original.png")
        let context = CGContext(data: nil, width: 2_000, height: 1_000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2_000, height: 1_000))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 130, nil)
        let text = NSAttributedString(string: "ANCHOR WORKFLOW TEST", attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 70, y: 470)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let writer = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(writer) else { fatalError("fixture") }
        let original = try Data(contentsOf: imageURL)

        let resized = try ShelfFileActions.run(.resize, urls: [imageURL], destination: outputs)
        try check(resized.files.count == 1, "resize produces one output")
        let source = CGImageSourceCreateWithURL(resized.files[0] as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        try check(properties[kCGImagePropertyPixelWidth] as? Int == 1_600, "maximum edge is 1600 pixels")
        try check(properties[kCGImagePropertyPixelHeight] as? Int == 800, "aspect ratio is preserved")
        let secondResize = try ShelfFileActions.run(.resize, urls: [imageURL], destination: outputs)
        try check(secondResize.files[0] != resized.files[0], "a repeated action never overwrites an earlier image")
        let jpeg = try ShelfFileActions.run(.jpeg, urls: [imageURL], destination: outputs)
        let jpegSource = CGImageSourceCreateWithURL(jpeg.files[0] as CFURL, nil)!
        try check(CGImageSourceGetType(jpegSource) as String? == UTType.jpeg.identifier, "JPEG output is really a JPEG")
        let originalAfter = try Data(contentsOf: imageURL)
        try check(originalAfter == original, "conversion preserves the original bytes")
        let pdfURL = outputs.appendingPathComponent("Combined.pdf")
        let pdf = try ShelfFileActions.run(.pdf, urls: [imageURL, resized.files[0]], destination: pdfURL)
        try check(PDFDocument(url: pdf.files[0])?.pageCount == 2, "images combine into a two-page PDF")
        let merged = outputs.appendingPathComponent("Merged.pdf")
        _ = try ShelfFileActions.run(.pdf, urls: [pdfURL, imageURL], destination: merged)
        try check(PDFDocument(url: merged)?.pageCount == 3, "PDF pages and images combine in order")
        let ocr = try ShelfFileActions.run(.ocr, urls: [imageURL], destination: nil)
        try check(ocr.text?.contains("ANCHOR") == true, "local OCR recognizes actual image text")

        var inputs: [URL] = []
        for (name, contents) in [("A", "first"), ("B", "second")] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("same name.txt")
            try Data(contents.utf8).write(to: file)
            inputs.append(file)
        }
        let zipURL = outputs.appendingPathComponent("Archive.zip")
        _ = try ShelfFileActions.run(.zip, urls: inputs, destination: zipURL)
        let extracted = root.appendingPathComponent("Extracted")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zipURL.path, "-d", extracted.path]
        try process.run(); process.waitUntilExit()
        try check(process.terminationStatus == 0, "generated ZIP extracts successfully")
        let first = try String(contentsOf: extracted.appendingPathComponent("same name.txt"), encoding: .utf8)
        let second = try String(contentsOf: extracted.appendingPathComponent("same name-2.txt"), encoding: .utf8)
        try check(first == "first" && second == "second", "same-named files from different folders retain their contents")
        let propertiesA = try extracted.appendingPathComponent("same name.txt").resourceValues(forKeys: [.isSymbolicLinkKey])
        try check(propertiesA.isSymbolicLink != true, "ZIP stores file contents rather than source symlinks")
        if CommandLine.arguments.contains("--preview") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory); app.finishLaunching()
            ShelfFileActions.shared.preview([imageURL])
            let preview = QLPreviewPanel.shared()!
            preview.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            try check(preview.isVisible, "native Quick Look opens")
            try check(preview.currentPreviewItem?.previewItemURL == imageURL, "native Quick Look displays the selected file")
            preview.close()
        }
        print("Native shelf actions: \(checks)/\(checks) passed")
    }
}
