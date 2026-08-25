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
import Combine
import Foundation

struct LauncherApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleIdentifier: String?

    var id: String { url.path }

    static func == (lhs: LauncherApp, rhs: LauncherApp) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

struct LauncherResult: Identifiable {
    let app: LauncherApp
    let matchedIndices: [Int]
    var id: String { app.id }
}

/// Discovers installed applications and ranks them for the launcher.
///
/// Directory scanning rather than `NSMetadataQuery`: a Spotlight query keeps a
/// live result set and wakes us on every index change, which is exactly the kind
/// of ambient cost this app is trying to avoid. A full scan of the standard
/// locations takes a few tens of milliseconds and only runs when the index is
/// stale or an app directory actually changed.
@MainActor
final class AppIndex: ObservableObject {
    static let shared = AppIndex()

    @Published private(set) var apps: [LauncherApp] = []
    @Published private(set) var isIndexing = false

    private var lastScan: Date = .distantPast
    private var directoryWatchers: [DispatchSourceFileSystemObject] = []

    /// Re-scan if the index is older than this when the panel opens.
    private static let staleAfter: TimeInterval = 300

    private nonisolated static let searchRoots: [URL] = {
        var roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
            // Safari and friends live in a cryptex and appear in /Applications
            // only as symlinks, which contentsOfDirectory does not return — so
            // the real location has to be scanned directly or Safari is missing.
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"),
        ]
        if let home = FileManager.default.homeDirectoryForCurrentUser as URL? {
            roots.append(home.appendingPathComponent("Applications"))
        }
        return roots
    }()

    private init() {}

    // MARK: - Indexing

    /// Rebuilds the index if it is stale. Cheap to call on every panel open.
    func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastScan) > Self.staleAfter || apps.isEmpty else { return }
        refresh()
    }

    func refresh() {
        guard !isIndexing else { return }
        isIndexing = true

        Task.detached(priority: .userInitiated) {
            let found = Self.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apps = found
                self.lastScan = Date()
                self.isIndexing = false
                self.startWatchingIfNeeded()
                // Rasterising icons is the slow part of showing the grid; do it
                // now rather than when the user is waiting on it.
                AppIconCache.shared.warm(found)
            }
        }
    }

    private nonisolated static func scan() -> [LauncherApp] {
        let fm = FileManager.default
        var seen = Set<URL>()
        var results: [LauncherApp] = []

        for root in searchRoots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for entry in entries {
                if entry.pathExtension == "app" {
                    insert(entry, into: &results, seen: &seen)
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // One level down only — catches /Applications/Adobe/Foo.app
                    // without walking deep trees on every scan.
                    let nested = (try? fm.contentsOfDirectory(
                        at: entry, includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
                    for child in nested where child.pathExtension == "app" {
                        insert(child, into: &results, seen: &seen)
                    }
                }
            }
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func insert(
        _ url: URL, into results: inout [LauncherApp], seen: inout Set<URL>
    ) {
        let standardized = url.standardizedFileURL
        guard !seen.contains(standardized) else { return }
        seen.insert(standardized)

        let bundle = Bundle(url: standardized)
        // Prefer the localized display name the Finder shows.
        let name =
            FileManager.default.displayName(atPath: standardized.path)
            .replacingOccurrences(of: ".app", with: "")

        results.append(
            LauncherApp(
                url: standardized,
                name: name,
                bundleIdentifier: bundle?.bundleIdentifier
            ))
    }

    /// Watches the application directories so a newly installed app appears
    /// without waiting for the staleness timer. Event-driven, no polling.
    private func startWatchingIfNeeded() {
        guard directoryWatchers.isEmpty else { return }

        for root in Self.searchRoots {
            let descriptor = open(root.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write], queue: .main)
            source.setEventHandler { [weak self] in
                // Debounce: installers touch the directory repeatedly.
                self?.lastScan = .distantPast
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            directoryWatchers.append(source)
        }
    }

    // MARK: - Search

    /// Ranked results for `query`. An empty query returns the frecency ordering.
    func search(_ query: String, limit: Int = 40) -> [LauncherResult] {
        let history = LaunchHistory.shared
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            var ranked: [(app: LauncherApp, score: Double)] = []
            ranked.reserveCapacity(apps.count)
            for app in apps {
                ranked.append((app: app, score: history.score(for: app.id)))
            }
            ranked.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
            }
            return ranked.prefix(limit).map { LauncherResult(app: $0.app, matchedIndices: []) }
        }

        var scored: [(app: LauncherApp, score: Double, indices: [Int])] = []
        scored.reserveCapacity(apps.count)
        for app in apps {
            guard let match = FuzzyMatcher.match(query: trimmed, candidate: app.name) else { continue }
            // Frecency nudges ties without letting a favourite outrank a clearly
            // better textual match.
            let combined = Double(match.score) + history.score(for: app.id) * 4
            scored.append((app: app, score: combined, indices: match.matchedIndices))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.app.name.count < rhs.app.name.count
        }
        return scored.prefix(limit).map {
            LauncherResult(app: $0.app, matchedIndices: $0.indices)
        }
    }

    // MARK: - Launching

    func launch(_ app: LauncherApp) {
        LaunchHistory.shared.recordLaunch(app.id)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, error in
            if let error {
                NSLog("AppIndex: failed to launch \(app.name): \(error.localizedDescription)")
            }
        }
    }
}
