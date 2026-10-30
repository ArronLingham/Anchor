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
    let category: AppCategory
    let searchAliases: [String]

    var id: String { url.path }
    var isSearchOnly: Bool { LauncherAppVisibility.isSearchOnly(url: url, bundleIdentifier: bundleIdentifier) }

    init(url: URL, name: String, bundleIdentifier: String?, category: AppCategory = .other, searchAliases: [String] = []) {
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.category = category
        self.searchAliases = searchAliases
    }

    static func == (lhs: LauncherApp, rhs: LauncherApp) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

struct LauncherResult: Identifiable {
    let app: LauncherApp
    let matchedIndices: [Int]
    let score: Double
    var id: String { app.id }

    init(app: LauncherApp, matchedIndices: [Int], score: Double = 0) {
        self.app = app
        self.matchedIndices = matchedIndices
        self.score = score
    }
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
    private var directoryMonitor: ApplicationDirectoryMonitor?
    private var launcherSubscription: AnyCancellable?
    private var scanGeneration = UUID()
    private var refreshPending = false

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

    private init() {
        launcherSubscription = Defaults.publisher(.enableLauncher, options: [])
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.syncMonitoring() } }
        syncMonitoring()
    }

    private func syncMonitoring() {
        guard Defaults[.enableLauncher] else {
            directoryMonitor?.stop()
            directoryMonitor = nil
            // A scan already running must not repopulate the disabled index or
            // enqueue a full icon warm after the user has switched it off.
            scanGeneration = UUID()
            refreshPending = false
            isIndexing = false
            if !apps.isEmpty { apps.removeAll() }
            rootMTimes.removeAll()
            return
        }
        if directoryMonitor == nil {
            directoryMonitor = ApplicationDirectoryMonitor(directories: Self.searchRoots) { [weak self] in
                Task { @MainActor [weak self] in
                    guard Defaults[.enableLauncher] else { return }
                    self?.refresh()
                }
            }
        }
        refreshIfNeeded()
    }

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
        guard Defaults[.enableLauncher] || UISnapshotHarness.requestedDirectory != nil else { return }
        // A filesystem change may arrive after a scan has passed the affected
        // directory. Remember it instead of silently accepting a stale result.
        guard !isIndexing else {
            refreshPending = true
            return
        }
        isIndexing = true
        let generation = UUID()
        scanGeneration = generation

        Task.detached(priority: .userInitiated) {
            let found = Self.scan()
            var newMTimes: [URL: TimeInterval] = [:]
            for root in Self.searchRoots {
                let mtime = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
                newMTimes[root] = mtime
            }
            
            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == generation,
                      Defaults[.enableLauncher] || UISnapshotHarness.requestedDirectory != nil else { return }
                self.apps = found
                self.rootMTimes = newMTimes
                self.isIndexing = false
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                    return
                }
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

        let category = AppCategory.category(for: bundle, url: standardized)

        results.append(
            LauncherApp(
                url: standardized,
                name: name,
                bundleIdentifier: bundle?.bundleIdentifier,
                category: category,
                searchAliases: [
                    standardized.deletingPathExtension().lastPathComponent,
                    bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "",
                    bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ""
                ] + LauncherSearch.aliases(for: bundle?.bundleIdentifier)
            ))
    }

    /// Applications belonging to a given category.
    func apps(in category: AppCategory) -> [LauncherApp] {
        openingApps.filter { $0.category == category }
    }

    /// The home grid, folders and categories share the same uncluttered set.
    /// The complete index remains available to search and the app switcher.
    var openingApps: [LauncherApp] { apps.filter { !$0.isSearchOnly } }

    // MARK: - Search

    /// Ranked results for `query`. An empty query returns the frecency ordering.
    func search(_ query: String, limit: Int = 40) -> [LauncherResult] {
        guard limit > 0 else { return [] }
        let history = LaunchHistory.shared
        let trimmed = LauncherSearch.normalizedQuery(query)

        guard !trimmed.isEmpty else {
            return orderedForEmptyQuery(history: history, limit: limit)
        }

        var scored: [(app: LauncherApp, match: LauncherSearch.Match)] = []
        scored.reserveCapacity(apps.count)

        let folders = Defaults[.launcherFolders]
        var appFolders: [String: [String]] = [:]
        for (folderName, appIDs) in folders {
            for id in appIDs {
                appFolders[id, default: []].append(folderName)
            }
        }

        for app in apps {
            let document = LauncherSearch.Document(
                name: app.name, aliases: app.searchAliases,
                context: [app.category.rawValue] + (appFolders[app.id] ?? []).sorted())
            if let match = LauncherSearch.match(query: trimmed, document: document, frecency: history.score(for: app.id)) {
                scored.append((app, match))
            }
        }

        scored.sort { lhs, rhs in
            if lhs.match.tier != rhs.match.tier { return lhs.match.tier > rhs.match.tier }
            if lhs.app.isSearchOnly != rhs.app.isSearchOnly { return !lhs.app.isSearchOnly }
            if lhs.match.outranks(rhs.match) { return true }
            if rhs.match.outranks(lhs.match) { return false }
            let order = lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name)
            return order == .orderedSame ? lhs.app.id < rhs.app.id : order == .orderedAscending
        }
        return scored.prefix(max(0, limit)).map {
            LauncherResult(app: $0.app, matchedIndices: $0.match.indices, score: $0.match.score)
        }
    }

    /// The order the grid uses when nothing has been typed.
    ///
    /// Frecency is only one of four answers people want here, so it is a
    /// setting. Every mode falls back to alphabetical for ties, which keeps the
    /// order stable rather than reshuffling equal-scoring apps on each open.
    private func orderedForEmptyQuery(history: LaunchHistory, limit: Int) -> [LauncherResult] {
        let apps = openingApps
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
            let rank = LauncherSearch.customOrderRanks(order)
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
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, error in
            if let error {
                NSLog("AppIndex: failed to launch \(app.name): \(error.localizedDescription)")
            } else {
                LaunchHistory.shared.recordLaunch(app.id)
            }
        }
    }
}
