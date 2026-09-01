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

// MARK: - Pure classification

/// What the cleaner is willing to touch, and what removing it costs.
///
/// ## Allowlist, never a scan
///
/// Every location is named explicitly below. The cleaner does not walk the home
/// directory looking for things that "look like" caches — a heuristic that is
/// wrong once has deleted someone's work. If a location is not in this list the
/// cleaner cannot reach it, whatever the user types.
///
/// ## The Trash is deliberately absent
///
/// Emptying the Trash is the one operation here that is not reversible, and it
/// is therefore not offered at all. Everything this cleaner removes goes *to*
/// the Trash, so the user can always undo it in one drag; a feature that then
/// emptied the Trash would quietly destroy that guarantee.
enum CleanupCategory: String, CaseIterable, Identifiable {
    case userCaches
    case userLogs
    case crashReports
    case xcodeDerivedData
    case xcodeDeviceSupport
    case simulatorCaches
    case npmCache
    case homebrewCache

    var id: String { rawValue }

    /// Path relative to the user's home directory.
    var relativePath: String {
        switch self {
        case .userCaches:         return "Library/Caches"
        case .userLogs:           return "Library/Logs"
        case .crashReports:       return "Library/Application Support/CrashReporter"
        case .xcodeDerivedData:   return "Library/Developer/Xcode/DerivedData"
        case .xcodeDeviceSupport: return "Library/Developer/Xcode/iOS DeviceSupport"
        case .simulatorCaches:    return "Library/Developer/CoreSimulator/Caches"
        case .npmCache:           return ".npm/_cacache"
        case .homebrewCache:      return "Library/Caches/Homebrew"
        }
    }

    var title: String {
        switch self {
        case .userCaches:         return "Application caches"
        case .userLogs:           return "Application logs"
        case .crashReports:       return "Crash reports"
        case .xcodeDerivedData:   return "Xcode derived data"
        case .xcodeDeviceSupport: return "Xcode device support"
        case .simulatorCaches:    return "Simulator caches"
        case .npmCache:           return "npm cache"
        case .homebrewCache:      return "Homebrew downloads"
        }
    }

    /// What the user actually loses. Shown in the UI, because "caches" sounds
    /// free and some of these are not.
    var consequence: String {
        switch self {
        case .userCaches:
            return "Apps rebuild these on next launch. Some will be slower once, and a few will sign you out."
        case .userLogs:
            return "Only useful for diagnosing something that already happened."
        case .crashReports:
            return "Past crash logs. Keep them if you are still chasing a bug."
        case .xcodeDerivedData:
            return "Your next build of every project is a full build."
        case .xcodeDeviceSupport:
            return "Re-downloaded when you next attach a device on that iOS version."
        case .simulatorCaches:
            return "Rebuilt by the simulator on demand."
        case .npmCache:
            return "npm re-downloads packages instead of using the local copy."
        case .homebrewCache:
            return "Downloaded bottles. brew re-fetches them when it needs them."
        }
    }

    /// Whether this is ticked by default.
    ///
    /// Only the three that cost nothing but time-to-rebuild. Anything that
    /// signs the user out, forces a full Xcode build, or re-downloads gigabytes
    /// starts unticked — the default must never be the expensive choice.
    var isDefaultSelected: Bool {
        switch self {
        case .userLogs, .crashReports, .simulatorCaches: return true
        case .userCaches, .xcodeDerivedData, .xcodeDeviceSupport,
             .npmCache, .homebrewCache: return false
        }
    }
}

/// The safety rules, kept pure so they can be tested without a disk.
enum CleanupSafety {

    /// Paths that must never be removed, whatever a category resolves to.
    ///
    /// This is a backstop, not the primary defence — the allowlist above is.
    /// It exists because a bug that made `relativePath` return "" would
    /// otherwise resolve to the home directory itself.
    static func isForbidden(_ path: String) -> Bool {
        let normalised = (path as NSString).standardizingPath
        let home = (NSHomeDirectory() as NSString).standardizingPath

        // Empty, root, or the home directory itself.
        if normalised.isEmpty || normalised == "/" || normalised == home { return true }
        // Anything outside the home directory. The cleaner is user-domain only;
        // /Library and /System need admin rights and are not its business.
        guard normalised.hasPrefix(home + "/") else { return true }
        // The Trash: everything here moves *into* it, so emptying it would
        // destroy the undo this whole design depends on.
        if normalised == home + "/.Trash" || normalised.hasPrefix(home + "/.Trash/") {
            return true
        }
        // Obvious user data, in case a future category is added carelessly.
        let protectedRoots = ["Desktop", "Documents", "Downloads", "Pictures",
                              "Movies", "Music", "Public", "Applications"]
        for root in protectedRoots where normalised == home + "/" + root
            || normalised.hasPrefix(home + "/" + root + "/") {
            return true
        }
        return false
    }

    /// Whether a category's resolved path is safe to act on.
    static func isCleanable(_ category: CleanupCategory, resolvedPath: String) -> Bool {
        guard !isForbidden(resolvedPath) else { return false }
        // The path must actually be the one this category names — a guard
        // against a category being pointed somewhere else by a bad edit.
        return resolvedPath.hasSuffix(category.relativePath)
    }

    /// Human-readable size. Decimal units, matching Finder.
    static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 bytes" }
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1000, index < units.count - 1 { value /= 1000; index += 1 }
        return index == 0
            ? "\(Int(value)) \(units[index])"
            : String(format: "%.1f %@", value, units[index])
    }
}

// MARK: - Manager

/// Finds reclaimable space and, on confirmation, moves it to the Trash.
///
/// ## Nothing is ever deleted
///
/// Every removal is `trashItem`, never `removeItem` — the same rule
/// `AppUninstaller` follows, for the same reason: this code decides what to get
/// rid of on someone's behalf, and the only acceptable failure mode is one they
/// can undo by dragging a folder back.
///
/// ## Cost
///
/// Nothing runs unless the user opens the pane and presses Scan. There is no
/// timer, no watcher, and no work at launch.
@MainActor
final class CleanupManager: ObservableObject {
    static let shared = CleanupManager()

    struct Finding: Identifiable, Equatable {
        let category: CleanupCategory
        let path: String
        let bytes: Int64
        var isSelected: Bool

        var id: String { category.rawValue }
    }

    @Published private(set) var findings: [Finding] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastResult: String?

    private init() {}

    var selectedBytes: Int64 {
        findings.filter(\.isSelected).reduce(0) { $0 + $1.bytes }
    }

    func toggle(_ id: String) {
        guard let index = findings.firstIndex(where: { $0.id == id }) else { return }
        findings[index].isSelected.toggle()
    }

    /// Measures each allowlisted location. Runs off the main actor — walking
    /// six gigabytes of caches on the main thread would hang the UI.
    func scan() async {
        isScanning = true
        lastResult = nil
        defer { isScanning = false }

        let home = NSHomeDirectory()
        let results = await Task.detached(priority: .utility) { () -> [Finding] in
            var found: [Finding] = []
            for category in CleanupCategory.allCases {
                let path = (home as NSString).appendingPathComponent(category.relativePath)
                guard CleanupSafety.isCleanable(category, resolvedPath: path),
                      FileManager.default.fileExists(atPath: path)
                else { continue }
                let bytes = Self.directorySize(at: URL(fileURLWithPath: path))
                guard bytes > 0 else { continue }
                found.append(Finding(category: category, path: path, bytes: bytes,
                                     isSelected: category.isDefaultSelected))
            }
            return found.sorted { $0.bytes > $1.bytes }
        }.value

        findings = results
    }

    /// Moves the selected locations' *contents* to the Trash.
    ///
    /// The contents, not the directory: removing `~/Library/Caches` itself
    /// makes macOS and every app recreate it, and some handle that badly. The
    /// directory stays; what is inside it goes.
    func cleanSelected() -> String {
        var moved: Int64 = 0
        var failures = 0

        for finding in findings where finding.isSelected {
            // Re-check at the point of action, not just at scan time.
            guard CleanupSafety.isCleanable(finding.category, resolvedPath: finding.path)
            else { continue }

            let url = URL(fileURLWithPath: finding.path)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil) else { continue }

            for entry in entries {
                guard !CleanupSafety.isForbidden(entry.path) else { continue }
                let size = Self.directorySize(at: entry)
                do {
                    try FileManager.default.trashItem(at: entry, resultingItemURL: nil)
                    moved += size
                } catch {
                    // A file in use, or owned by another user. Expected, and not
                    // worth stopping for — report the count rather than failing
                    // the whole clean.
                    failures += 1
                }
            }
        }

        let summary = failures == 0
            ? "Moved \(CleanupSafety.formatBytes(moved)) to the Trash."
            : "Moved \(CleanupSafety.formatBytes(moved)) to the Trash. \(failures) item\(failures == 1 ? "" : "s") could not be moved — usually in use."
        lastResult = summary
        NSLog("Cleanup: \(summary)")
        return summary
    }

    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let v = try? child.resourceValues(forKeys: Set(keys)),
                  v.isDirectory != true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }
}
