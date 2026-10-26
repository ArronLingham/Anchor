import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

extension ClipboardItem {
    var searchDocument: ClipboardSearchDocument {
        .init(type: type.rawValue,
              text: [stringData, preview, fileURLs?.joined(separator: " ")].compactMap { $0 }.joined(separator: " "),
              source: [sourceAppName, sourceBundleIdentifier].compactMap { $0 }.joined(separator: " "),
              collection: collectionName ?? "")
    }
}

struct ClipboardWorkflowBar: View {
    @Binding var query: String
    @ObservedObject private var clipboard = ClipboardManager.shared

    var body: some View {
        HStack {
            Menu {
                Button("All content") { query = "" }
                Button("Text") { query = "@text " }
                Button("Images") { query = "@image " }
                Button("Files") { query = "@file " }
                Button("Links") { query = "@link " }
                let collections = Set(clipboard.pinnedItems.compactMap(\.collectionName)).sorted()
                if !collections.isEmpty { Divider() }
                ForEach(collections, id: \.self) { name in Button(name) { query = "@board:" + name } }
            } label: { Label("Filter", systemImage: "line.3.horizontal.decrease") }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Button { clipboard.setCapturePaused(!clipboard.isCapturePaused) } label: {
                Label(clipboard.isCapturePaused ? "Resume" : "Pause", systemImage: clipboard.isCapturePaused ? "play.fill" : "pause.fill")
            }.buttonStyle(.plain)
                .help(clipboard.isCapturePaused ? "Resume saving new copies" : "Pause clipboard capture")
        }.font(.caption2)
        .onAppear { clipboard.refreshRetention() }
    }
}

struct ClipboardItemContextMenu: View {
    let item: ClipboardItem
    @ObservedObject private var manager = ClipboardManager.shared

    var body: some View {
        Button("Copy") { manager.copyToClipboard(item) }
        if let text = item.stringData {
            Button("View full text…") { manager.previewText(text) }
            Menu("Copy transformed text") {
                ForEach(ClipboardTextTransform.allCases) { transform in
                    Button(transform.rawValue) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transform.apply(text), forType: .string)
                        manager.ignoreChangeCount(NSPasteboard.general.changeCount)
                    }
                }
            }
        }
        Button(item.isPinned ? "Unpin" : "Pin") { manager.togglePin(for: item) }
        Button("Save to collection…") { manager.chooseCollection(for: item) }
        if item.collectionName != nil { Button("Remove collection label") { manager.assignCollection(nil, to: item) } }
        Divider()
        Button("Delete", role: .destructive) { manager.deleteItem(item) }
    }
}

@MainActor
extension ClipboardManager {
    func previewText(_ text: String) {
        let alert = NSAlert(); alert.messageText = "Clipboard text"
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        view.string = text; view.isEditable = false; view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view; scroll.hasVerticalScroller = true
        alert.accessoryView = scroll; alert.addButton(withTitle: "Done"); alert.runModal()
    }

    func chooseCollection(for item: ClipboardItem) {
        let alert = NSAlert(); alert.messageText = "Save to collection"
        alert.informativeText = "This pins the item so it survives history cleanup."
        let field = NSTextField(string: item.collectionName ?? "")
        field.placeholderString = "Collection name"; field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
            if !name.isEmpty { assignCollection(name, to: item) }
        }
    }

    func assignCollection(_ name: String?, to item: ClipboardItem) {
        if name != nil && !pinnedItems.contains(where: { $0.id == item.id }) { pinItem(item) }
        if let index = pinnedItems.firstIndex(where: { $0.id == item.id }) {
            pinnedItems[index].collectionName = name
            savePinnedItemsToDefaults()
        }
        if let index = clipboardHistory.firstIndex(where: { $0.id == item.id }) {
            clipboardHistory[index].collectionName = name
            saveHistoryToDefaults()
        }
    }

    private struct Backup: Codable {
        var version = 1
        var entries: [Entry]
        struct Entry: Codable { var item: ClipboardItem; var image: Data? }
    }

    func exportBackup() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Anchor Clipboard.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entries = (pinnedItems + clipboardHistory).map { Backup.Entry(item: $0, image: $0.getImageData()) }
            guard !entries.contains(where: { $0.item.type == .image && $0.image == nil }) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let data = try JSONEncoder().encode(Backup(entries: entries))
            guard data.count <= 50_000_000 else { throw CocoaError(.fileReadTooLarge) }
            try data.write(to: url, options: .atomic)
            workflowMessage = "Exported \(entries.count) items."
        } catch { workflowMessage = "Backup failed: " + error.localizedDescription }
    }

    func importBackup() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 50_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let backup = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
            guard backup.version == 1, backup.entries.count <= 2_000,
                  backup.entries.allSatisfy({ ($0.item.stringData?.utf8.count ?? 0) <= 1_000_000 && ($0.image?.count ?? 0) <= 10_000_000 }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var history = clipboardHistory, pins = pinnedItems, createdFiles: [URL] = [], imported = 0
            do {
                for entry in backup.entries {
                    var item = entry.item
                    item.imageFileName = nil
                    if item.type == .image {
                        guard let data = entry.image, NSImage(data: data) != nil else { throw CocoaError(.fileReadCorruptFile) }
                        let name = "clipboard_image_\(UUID().uuidString).png"
                        let output = Self.clipboardDataDirectory.appendingPathComponent(name)
                        try data.write(to: output, options: .withoutOverwriting)
                        createdFiles.append(output); item.imageFileName = name
                    }
                    if (history + pins).contains(where: { isSameContent($0, item) }) {
                        if let name = item.imageFileName {
                            let file = Self.clipboardDataDirectory.appendingPathComponent(name)
                            try? FileManager.default.removeItem(at: file)
                            createdFiles.removeAll { $0 == file }
                        }
                        continue
                    }
                    if (history + pins).contains(where: { $0.id == item.id }) { item.id = UUID() }
                    if item.isPinned { pins.append(item) } else { history.append(item) }
                    imported += 1
                }
            } catch {
                createdFiles.forEach { try? FileManager.default.removeItem(at: $0) }
                throw error
            }
            clipboardHistory = Array(history.sorted { $0.timestamp > $1.timestamp }.prefix(min(500, max(1, Defaults[.clipboardHistorySize]))))
            pinnedItems = pins
            saveHistoryToDefaults(); savePinnedItemsToDefaults(); refreshRetention()
            workflowMessage = "Imported \(imported) new items."
        } catch { workflowMessage = "Import failed: " + error.localizedDescription }
    }
}
