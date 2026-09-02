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
import Defaults
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

    private var rootMTimes: [URL: TimeInterval] = [:]

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
        var stale = apps.isEmpty
        
        for root in Self.searchRoots {
            let mtime = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            if rootMTimes[root] != mtime {
                stale = true
                break
            }
        }
        
        guard stale else { return }
        refresh()
    }

    func refresh() {
        guard !isIndexing else { return }
        isIndexing = true

        Task.detached(priority: .userInitiated) {
            let found = Self.scan()
            var newMTimes: [URL: TimeInterval] = [:]
            for root in Self.searchRoots {
                let mtime = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
                newMTimes[root] = mtime
            }
            
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apps = found
                self.rootMTimes = newMTimes
                self.isIndexing = false
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
                includingPropertiesForKeys: [.isApplicationKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for entry in entries {
                let isSymlink = (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                let urlToTest = isSymlink ? entry.resolvingSymlinksInPath() : entry
                
                let isApp = (try? urlToTest.resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true
                
                if urlToTest.pathExtension == "app" || isApp {
                    insert(urlToTest, into: &results, seen: &seen)
                } else if (try? urlToTest.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // One level down only — catches /Applications/Adobe/Foo.app
                    // without walking deep trees on every scan.
                    let nested = (try? fm.contentsOfDirectory(
                        at: urlToTest, includingPropertiesForKeys: [.isApplicationKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
                    for child in nested {
                        let childSym = (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                        let childToTest = childSym ? child.resolvingSymlinksInPath() : child
                        let childIsApp = (try? childToTest.resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true
                        
                        if childToTest.pathExtension == "app" || childIsApp {
                            insert(childToTest, into: &results, seen: &seen)
                        }
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

    // MARK: - Search

    /// Ranked results for `query`. An empty query returns the frecency ordering.
    func search(_ query: String, limit: Int = 40) -> [LauncherResult] {
        let history = LaunchHistory.shared
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            return orderedForEmptyQuery(history: history, limit: limit)
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

    /// The order the grid uses when nothing has been typed.
    ///
    /// Frecency is only one of four answers people want here, so it is a
    /// setting. Every mode falls back to alphabetical for ties, which keeps the
    /// order stable rather than reshuffling equal-scoring apps on each open.
    private func orderedForEmptyQuery(history: LaunchHistory, limit: Int) -> [LauncherResult] {
        let byName: (LauncherApp, LauncherApp) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        var ordered: [LauncherApp]
        switch Defaults[.launcherSortMode] {
        case .alphabetical:
            ordered = apps.sorted(by: byName)

        case .mostUsed:
            ordered = apps.sorted { lhs, rhs in
                let l = history.score(for: lhs.id), r = history.score(for: rhs.id)
                return l == r ? byName(lhs, rhs) : l > r
            }

        case .mostRecent:
            let last = Defaults[.launcherLastLaunched]
            ordered = apps.sorted { lhs, rhs in
                let l = last[lhs.id] ?? .distantPast, r = last[rhs.id] ?? .distantPast
                return l == r ? byName(lhs, rhs) : l > r
            }

        case .custom:
            // Placed apps first, in the user's order; everything else keeps its
            // alphabetical position behind them. A stored id for an app that is
            // no longer installed is simply skipped rather than leaving a hole.
            let order = Defaults[.launcherCustomOrder]
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            ordered = apps.sorted { lhs, rhs in
                switch (rank[lhs.id], rank[rhs.id]) {
                case let (l?, r?): return l < r
                case (_?, nil):    return true
                case (nil, _?):    return false
                default:           return byName(lhs, rhs)
                }
            }
        }

        return ordered.prefix(limit).map { LauncherResult(app: $0, matchedIndices: []) }
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
