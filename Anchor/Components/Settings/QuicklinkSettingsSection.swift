import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuicklinkSettingsSection: View {
    @ObservedObject private var manager = QuicklinkManager.shared
    @State private var editing: AnchorQuicklink?

    private func highlightID(_ title: String) -> String { SettingsTab.launcher.highlightID(for: title) }

    var body: some View {
        Section {
            ForEach(manager.links) { link in
                HStack {
                    Toggle(isOn: Binding(get: { link.isEnabled }, set: { enabled in
                        var changed = link; changed.isEnabled = enabled; manager.save(changed)
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.title)
                            Text(link.keyword + (link.needsQuery ? " search terms" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Edit") { editing = link }
                    Button(role: .destructive) { manager.remove(link) } label: { Image(systemName: "trash") }
                        .help("Delete \(link.title)")
                }
            }
            Button("Add quicklink…") { editing = AnchorQuicklink(title: "", keyword: "", target: "https://") }
                .settingsHighlight(id: highlightID("Add quicklink"))
            if let error = manager.error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: { Text("Quicklinks & web search") }
        footer: { Text("Type a keyword in the launcher: g macOS, gh swift, or yt piano. Add your own websites, searches, files, and folders. URLs open only when you select a result.") }
        .sheet(item: $editing) { link in
            QuicklinkEditor(draft: link) { changed in
                if manager.save(changed) { editing = nil }
            }
        }
    }
}

private struct QuicklinkEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: AnchorQuicklink
    let onSave: (AnchorQuicklink) -> Void
    @ObservedObject private var manager = QuicklinkManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Quicklink").font(.title2.bold())
            Form {
                TextField("Name", text: $draft.title)
                TextField("Keyword", text: $draft.keyword)
                TextField("URL", text: $draft.target)
                Button("Choose file or folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true; panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { draft.target = url.absoluteString }
                }
            }
            Text("For a search, use {query}: https://example.com/search?q={query}")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let error = manager.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }.keyboardShortcut(.defaultAction)
                    .disabled(draft.validationError != nil)
            }
        }.padding(24).frame(width: 500)
        .onAppear { manager.error = nil }
    }
}
