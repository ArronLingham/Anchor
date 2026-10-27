import AppKit
import AnchorUtilities
import SwiftUI
import UniformTypeIdentifiers

/// Shared by the notch and dashboard; every action uses the same persisted shelf.
struct ShelfWorkspaceView: View {
    var seamless = false
    @ObservedObject private var shelf = ShelfManager.shared
    @ObservedObject private var actions = ShelfFileActions.shared
    @State private var selected = Set<UUID>()
    @State private var query = ""
    @AppStorage("AnchorShelfSort") private var sort = "recent"
    @State private var isTargeted = false
    @FocusState private var searchFocused: Bool

    private var visible: [ShelfManager.Item] {
        shelf.items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { a, b in
                if a.isPinned != b.isPinned { return a.isPinned == true }
                switch sort {
                case "name": return a.name.localizedStandardCompare(b.name) == .orderedAscending
                case "kind":
                    let ae = (a.name as NSString).pathExtension, be = (b.name as NSString).pathExtension
                    if ae != be { return ae.localizedStandardCompare(be) == .orderedAscending }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                default: return a.addedAt > b.addedAt
                }
            }
    }
    private var picked: [ShelfManager.Item] { visible.filter { selected.contains($0.id) } }
    private var urls: [URL] { picked.compactMap { shelf.resolve($0) } }

    var body: some View {
        VStack(spacing: 6) {
            toolbar
            if shelf.items.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down").font(.title2)
                    Text("Drop files here").font(.headline)
                    Text("Collect, preview, share, or convert them.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 65)
            } else if visible.isEmpty {
                Text("No matching files").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 65)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(visible) { tile($0) } }.padding(2)
                }
            }
            if actions.isWorking { ProgressView("Working…").controlSize(.small) }
            if let message = actions.message ?? shelf.storageError {
                Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(seamless ? 0 : 8)
        .background(AnchorCorners.rectangle(cornerRadius: 12).fill(isTargeted ? Color.accentColor.opacity(0.15) : .clear))
        .overlay(AnchorCorners.rectangle(cornerRadius: 12).anchorStrokeBorder(isTargeted ? Color.accentColor : Color.primary.opacity(seamless ? 0 : 0.08)))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: load)
        .focusable()
        .onKeyPress(.space) {
            guard !searchFocused, !urls.isEmpty else { return .ignored }
            actions.preview(urls); return .handled
        }
        .onChange(of: shelf.items) { _, items in selected.formIntersection(Set(items.map(\.id))) }
    }

    private var toolbar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find files", text: $query).textFieldStyle(.plain).focused($searchFocused)
                .frame(minWidth: 60)
            Menu {
                Picker("Sort", selection: $sort) {
                    Text("Newest first").tag("recent"); Text("Name").tag("name"); Text("Kind").tag("kind")
                }
                Button("Select all visible") { selected = Set(visible.map(\.id)) }
                Button("Clear selection") { selected = [] }
                Divider()
                Button("Clear unpinned files") { shelf.clearUnpinned() }
                    .disabled(shelf.items.allSatisfy { $0.isPinned == true })
            } label: { Image(systemName: "line.3.horizontal.decrease") }
            .menuStyle(.borderlessButton).frame(width: 18).help("Sort and selection")
            Button { shelf.chooseFiles() } label: { Image(systemName: "plus") }.help("Add files or folders")
            Button { shelf.pasteFiles() } label: { Image(systemName: "doc.on.clipboard") }.help("Paste files from Finder")
            Menu {
                Button("Quick Look") { actions.preview(urls) }.disabled(urls.isEmpty)
                Button("Copy files") { shelf.copyFiles(picked) }.disabled(picked.isEmpty)
                if !urls.isEmpty { ShareLink(items: urls) { Text("Share…") } }
                Divider()
                ForEach(ShelfFileActions.Action.allCases) { action in
                    Button(action.rawValue) { actions.perform(action, urls: urls) }
                        .disabled(!actions.available(action, urls: urls))
                }
                Divider()
                Button("Remove selected from shelf") { picked.forEach { shelf.remove($0) }; selected = [] }
                    .disabled(picked.isEmpty)
            } label: {
                Label(selected.isEmpty ? "Actions" : "\(picked.count)", systemImage: "ellipsis.circle")
            }.menuStyle(.borderlessButton).fixedSize().help("Actions for selected files")
        }.font(.caption).buttonStyle(.plain)
    }

    private func tile(_ item: ShelfManager.Item) -> some View {
        let available = shelf.resolve(item) != nil
        return VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = shelf.thumbnails[item.id] { Image(nsImage: image).resizable().scaledToFit() }
                    else { Image(systemName: available ? "doc" : "externaldrive.badge.exclamationmark").font(.title2).foregroundStyle(.secondary) }
                }.frame(width: 40, height: 40)
                if item.isPinned == true { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
            }
            Text(item.name).font(.system(size: 9)).lineLimit(1).truncationMode(.middle).frame(width: 68)
        }
        .padding(5).frame(width: 78, height: 70)
        .background(AnchorCorners.rectangle(cornerRadius: 8).fill(selected.contains(item.id) ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.04)))
        .overlay(AnchorCorners.rectangle(cornerRadius: 8).anchorStrokeBorder(selected.contains(item.id) ? Color.accentColor : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { shelf.open(item) }
        .onTapGesture {
            searchFocused = false
            if NSEvent.modifierFlags.contains(.command) {
                if !selected.insert(item.id).inserted { selected.remove(item.id) }
            } else { selected = [item.id] }
        }
        .onDrag {
            guard let url = shelf.resolve(item) else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Quick Look") { actions.preview(shelf.resolve(item).map { [$0] } ?? []) }.disabled(!available)
            Button("Open") { shelf.open(item) }.disabled(!available)
            Button("Reveal in Finder") { shelf.revealInFinder(item) }.disabled(!available)
            Button("Copy file") { shelf.copyFiles([item]) }.disabled(!available)
            if let url = shelf.resolve(item) { ShareLink(item: url) { Text("Share…") } }
            Button(item.isPinned == true ? "Unpin" : "Pin") { shelf.togglePin(item) }
            Divider()
            Button("Remove from shelf", role: .destructive) { shelf.remove(item) }
        }
        .help(available ? "\(item.name) · Click to select, ⌘-click for multiple, Space to preview" : "\(item.name) · File unavailable. Reconnect its volume or add it again.")
    }

    private func load(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in ShelfManager.shared.add(urls: [url]) }
            }
        }
        return !providers.isEmpty
    }
}
