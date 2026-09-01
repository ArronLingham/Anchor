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
import Foundation

/// Finds the files an app leaves behind, so removing it can take them too.
///
/// ## Nothing here deletes anything permanently
///
/// Every removal goes to the Trash via `NSFileManager.trashItem`, never
/// `removeItem`. A wrong guess is then recoverable by the user in one drag,
/// which is the only acceptable failure mode for code that decides what to
/// delete on someone's behalf.
///
/// ## Matching is conservative on purpose
///
/// Leftovers are found by bundle identifier, not by app name. A name match
/// would catch a "Notes" folder belonging to something else entirely; a bundle
/// id like `com.acme.widget` is specific enough that a false positive is
/// unlikely. The one name-based rule — an exact `Application Support`
/// directory named after the app — is common enough to be worth including and
/// is presented unticked for review rather than removed automatically.
enum AppUninstaller {

    /// A file or directory belonging to an app.
    struct Leftover: Identifiable, Equatable {
        let url: URL
        let kind: Kind
        /// Whether this is safe enough to tick by default. Only the bundle
        /// itself is; everything found by inference starts unticked.
        let isDefaultSelected: Bool

        var id: String { url.path }

        enum Kind: String {
            case bundle = "Application"
            case preferences = "Preferences"
            case applicationSupport = "Application Support"
            case caches = "Caches"
            case containers = "Container"
            case savedState = "Saved state"
            case logs = "Logs"
            case launchAgent = "Launch agent"
            case webKit = "WebKit data"
        }
    }

    /// The directories searched, relative to `~/Library`, and what a hit means.
    ///
    /// Deliberately user-domain only. `/Library` needs admin rights, and an
    /// app asking for those to tidy caches is a much bigger ask than the
    /// feature is worth — the system-domain leftovers are usually a launch
    /// daemon that the app's own uninstaller should handle.
    private static let searchRules: [(subpath: String, kind: Leftover.Kind, matchesPrefix: Bool)] = [
        ("Preferences", .preferences, true),
        ("Application Support", .applicationSupport, true),
        ("Caches", .caches, true),
        ("Containers", .containers, true),
        ("Group Containers", .containers, true),
        ("Saved Application State", .savedState, true),
        ("Logs", .logs, true),
        ("LaunchAgents", .launchAgent, true),
        ("WebKit", .webKit, true),
        ("HTTPStorages", .caches, true),
    ]

    /// Whether `filename` belongs to the app with `bundleID`.
    ///
    /// Pure, and the part most worth pinning: it decides what gets deleted.
    /// A file counts when its name is the bundle id, or the bundle id followed
    /// by a separator — so `com.acme.app.plist` and
    /// `com.acme.app.savedState` match, while `com.acme.apple.plist` (a
    /// different app whose id merely starts the same way) does not.
    static func matches(filename: String, bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if filename == bundleID { return true }
        guard filename.hasPrefix(bundleID) else { return false }
        // The next character must be a separator, not more identifier.
        let next = filename[filename.index(filename.startIndex, offsetBy: bundleID.count)]
        return next == "." || next == "-" || next == "_"
    }

    /// Everything found for an app, the bundle first.
    static func leftovers(forAppAt appURL: URL) -> [Leftover] {
        guard let bundle = Bundle(url: appURL),
              let bundleID = bundle.bundleIdentifier
        else {
            return [Leftover(url: appURL, kind: .bundle, isDefaultSelected: true)]
        }

        var found: [Leftover] = [
            Leftover(url: appURL, kind: .bundle, isDefaultSelected: true)
        ]

        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")

        for rule in searchRules {
            let directory = library.appendingPathComponent(rule.subpath)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            else { continue }

            for entry in entries where matches(filename: entry.lastPathComponent, bundleID: bundleID) {
                found.append(Leftover(url: entry, kind: rule.kind, isDefaultSelected: false))
            }
        }

        // The one name-based rule — many apps use a display-name folder in
        // Application Support rather than their bundle id.
        let appName = appURL.deletingPathExtension().lastPathComponent
        let namedSupport = library
            .appendingPathComponent("Application Support")
            .appendingPathComponent(appName)
        if FileManager.default.fileExists(atPath: namedSupport.path),
           !found.contains(where: { $0.url == namedSupport }) {
            found.append(Leftover(url: namedSupport, kind: .applicationSupport, isDefaultSelected: false))
        }

        return found
    }

    /// Moves the given items to the Trash.
    ///
    /// Returns what could not be moved, with why — a partial failure (a file
    /// owned by root, say) must not look like success.
    @discardableResult
    static func moveToTrash(_ leftovers: [Leftover]) -> [(url: URL, error: String)] {
        var failures: [(url: URL, error: String)] = []
        for leftover in leftovers {
            do {
                try FileManager.default.trashItem(at: leftover.url, resultingItemURL: nil)
            } catch {
                failures.append((leftover.url, error.localizedDescription))
            }
        }
        return failures
    }

    /// Total size on disk, for showing what is about to be reclaimed.
    static func totalSize(of leftovers: [Leftover]) -> Int64 {
        leftovers.reduce(into: Int64(0)) { total, leftover in
            total += directorySize(at: leftover.url)
        }
    }

    private static func directorySize(at url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }

        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let childValues = try? child.resourceValues(forKeys: Set(keys)),
                  childValues.isDirectory != true
            else { continue }
            total += Int64(childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? 0)
        }
        return total
    }
}
