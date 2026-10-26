import AppKit
import Combine
import Foundation

@MainActor
final class QuicklinkManager: ObservableObject {
    static let shared = QuicklinkManager()
    @Published private(set) var links: [AnchorQuicklink] = []
    @Published var error: String?
    private let defaults: UserDefaults
    private let storageKey = "AnchorQuicklinks.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey) {
            do { links = try JSONDecoder().decode([AnchorQuicklink].self, from: data) }
            catch { self.error = "Quicklinks could not be loaded. The saved data has been preserved." }
        } else {
            links = AnchorQuicklink.starters
        }
    }

    @discardableResult
    func save(_ link: AnchorQuicklink) -> Bool {
        if let message = link.validationError { error = message; return false }
        if links.contains(where: { $0.id != link.id && $0.keyword.caseInsensitiveCompare(link.keyword) == .orderedSame }) {
            error = "That keyword is already in use. Choose a different one."
            return false
        }
        var updated = links
        if let index = updated.firstIndex(where: { $0.id == link.id }) { updated[index] = link }
        else { updated.append(link) }
        return persist(updated)
    }

    func remove(_ link: AnchorQuicklink) { _ = persist(links.filter { $0.id != link.id }) }

    private func persist(_ updated: [AnchorQuicklink]) -> Bool {
        do {
            let data = try JSONEncoder().encode(updated)
            defaults.set(data, forKey: storageKey)
            links = updated
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func searchCommands(_ query: String) -> [LauncherCommand.ScoredCommand] {
        var results: [LauncherCommand.ScoredCommand] = []
        for link in links where link.isEnabled && link.validationError == nil {
            let argument = link.argument(in: query)
            let titleMatch = LauncherSearch.match(query: query, document: .init(name: link.title, aliases: [], context: []))
            guard argument != nil || (!link.needsQuery && titleMatch != nil) else { continue }
            let term = argument ?? ""
            guard !link.needsQuery || !term.isEmpty, let url = link.resolvedURL(query: term) else { continue }
            let command = LauncherCommand(
                id: "quicklink.\(link.id)",
                title: link.needsQuery ? "Search \(link.title) for “\(term)”" : link.title,
                subtitle: url.isFileURL ? url.path : (url.host ?? link.target),
                symbolName: url.isFileURL ? "folder" : (link.needsQuery ? "magnifyingglass" : "link"),
                keywords: [link.keyword]
            ) { NSWorkspace.shared.open(url) }
            results.append(.init(command: command, score: argument != nil ? 10_000 : Int(titleMatch?.score ?? 0), matchedIndices: []))
        }
        if let url = AnchorQuicklink.directWebURL(query) {
            let command = LauncherCommand(id: "quicklink.openURL", title: "Open \(url.host ?? query)",
                subtitle: url.absoluteString, symbolName: "globe", keywords: []) { NSWorkspace.shared.open(url) }
            results.append(.init(command: command, score: 10_001, matchedIndices: []))
        }
        return results
    }
}
