import AppKit
import SwiftUI

struct StorageReviewView: View {
    @StateObject private var review = StorageReview()
    @State private var root = FileManager.default.homeDirectoryForCurrentUser
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storage review").font(.title2.bold())
            Text("Find the 200 largest local files over 100 MB in a folder or disk. Nothing starts selected. Age and size do not mean a file is unused. System data, app bundles, Library data and cloud-only files are excluded; use Cleaner or Uninstaller for app data.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Choose folder or disk…") { choose() }.disabled(review.scanning || review.removing)
                Text(root.path).lineLimit(1).truncationMode(.middle)
                Spacer()
                if review.scanning { ProgressView().controlSize(.small); Button("Stop") { review.cancel() } }
                else { Button("Scan") { review.scan(root: root) }.disabled(review.removing) }
            }
            if !review.scanning {
                Text("\(review.inspected) entries checked · \(review.inaccessible) locations could not be read")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List(review.items) { item in
                HStack {
                    Toggle(isOn: Binding(get: { review.selected.contains(item.id) }, set: { on in
                        if on { review.selected.insert(item.id) } else { review.selected.remove(item.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.url.lastPathComponent).font(.body.weight(.medium))
                            Text(item.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if let date = item.modified { Text("Modified \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }.toggleStyle(.checkbox)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).monospacedDigit()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }
            }
            if let message = review.message { Text(message).font(.caption) }
            HStack {
                Text("Selected: \(review.selected.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Move selected files to Trash…", role: .destructive) { confirming = true }
                    .disabled(review.selected.isEmpty || review.scanning || review.removing)
            }
        }.padding(22)
        .background(WindowVisibilityReader { if !$0 { review.cancel() } })
        .onDisappear { review.cancel() }
        .confirmationDialog("Move \(review.selected.count) selected files to Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { review.trashSelected() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Review the paths first. You can restore these files from Trash; Anchor will not empty it.") }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.begin { response in if response == .OK, let url = panel.url { root = url } }
    }
}
