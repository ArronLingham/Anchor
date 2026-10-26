import AppKit
import Combine
import Foundation

/// Notices newly trashed bundles with file-system events. It never scans app
/// leftovers until Review is pressed and never removes anything automatically.
final class DeletedAppWatcher: ObservableObject {
    static let shared = DeletedAppWatcher()
    struct Candidate: Identifiable {
        var id: String { url.path }
        let url: URL
        let name: String
        let bundleID: String
    }
    @Published private(set) var candidates: [Candidate] = []
    private let queue = DispatchQueue(label: "com.anchor.deleted-apps", qos: .utility)
    private var watcher: AgentLogWatcher?
    private var known = Set<String>() // queue-confined
    private var generation = UUID() // queue-confined
    private var session = UUID() // main only
    private var enabled = false
    private let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")

    func sync() {
        let wanted = AppFeature.uninstaller.isAvailable
        guard wanted != enabled else { return }
        session = UUID()
        let token = session
        enabled = wanted
        if !wanted { candidates = [] }
        queue.async { [self] in
            generation = token
            if wanted {
                known = Set(bundleURLs().map(\.path))
                let events = AgentLogWatcher(queue: queue) { [weak self] _, _ in self?.changed() }
                watcher = events
                _ = events.start([trash.path])
            } else {
                watcher?.stop(); watcher = nil; known = []
            }
        }
    }
    private func bundleURLs() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "app" }
    }
    private func changed() {
        let token = generation
        let urls = bundleURLs()
        let paths = Set(urls.map(\.path))
        let new = urls.filter { !known.contains($0.path) }
        known = paths
        let found = new.compactMap { url -> Candidate? in
            guard let selection = UninstallerSupport.selection(for: url) else { return nil }
            return Candidate(url: url, name: url.deletingPathExtension().lastPathComponent, bundleID: selection.bundleID)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.enabled, self.session == token else { return }
            self.candidates.removeAll { !paths.contains($0.id) }
            self.candidates.append(contentsOf: found.filter { item in !self.candidates.contains { $0.id == item.id } })
            self.candidates = Array(self.candidates.suffix(10))
            if !found.isEmpty {
                Notifier.post(title: "App moved to Trash", body: "Open Anchor’s Uninstaller to review its caches, preferences, logs and leftovers.")
            }
        }
    }
    func review(_ candidate: Candidate) {
        // A restored/reinstalled app may now own these files. Refuse a stale
        // deletion suggestion; normal explicit uninstall remains available.
        let installed = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: candidate.bundleID)
        guard !installed.contains(where: { !$0.path.hasPrefix(trash.path + "/") && FileManager.default.fileExists(atPath: $0.path) }) else {
            candidates.removeAll { $0.id == candidate.id }; return
        }
        guard candidate.url.deletingLastPathComponent().standardizedFileURL == trash.standardizedFileURL else { return }
        if AppUninstaller.shared.select(appURL: candidate.url) {
            candidates.removeAll { $0.id == candidate.id }
        }
    }
}
