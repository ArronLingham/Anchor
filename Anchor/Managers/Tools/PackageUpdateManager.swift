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

// MARK: - Pure: version comparison

/// Orders two version strings.
///
/// Pure, and worth its own type because string comparison is wrong here in a
/// way that looks right: `"1.10" < "1.9"` lexically, so a naive implementation
/// reports an app as up to date for the whole of a `1.10` series. Every case
/// below is a shape seen in real `Info.plist` and Homebrew version fields.
enum VersionComparator {

    enum Order { case older, same, newer }

    /// How `lhs` relates to `rhs`.
    ///
    /// Numeric components compare numerically; a missing component is zero, so
    /// `2.0` and `2.0.0` are the *same* version rather than different ones.
    /// A trailing non-numeric suffix (`-beta`, `rc1`, `_1`) makes a version
    /// **older** than the same numbers without it, which is the convention
    /// semver uses and which matters because `1.0-beta` must not read as newer
    /// than `1.0`.
    static func compare(_ lhs: String, _ rhs: String) -> Order {
        let left = components(of: lhs)
        let right = components(of: rhs)

        for index in 0..<max(left.numbers.count, right.numbers.count) {
            let l = index < left.numbers.count ? left.numbers[index] : 0
            let r = index < right.numbers.count ? right.numbers[index] : 0
            if l != r { return l < r ? .older : .newer }
        }

        // Numbers equal. A pre-release suffix loses to no suffix.
        switch (left.suffix.isEmpty, right.suffix.isEmpty) {
        case (true, true):   return .same
        case (true, false):  return .newer   // 1.0 beats 1.0-beta
        case (false, true):  return .older   // 1.0-beta loses to 1.0
        case (false, false):
            if left.suffix == right.suffix { return .same }
            return left.suffix < right.suffix ? .older : .newer
        }
    }

    /// True when `available` is a genuine upgrade over `installed`.
    static func isUpgrade(installed: String, available: String) -> Bool {
        compare(installed, available) == .older
    }

    /// Splits a version into numeric components and a trailing suffix.
    ///
    /// Homebrew appends a revision as `_1` and Apple builds often carry a
    /// letter (`13.2b`), so the split has to tolerate both without treating the
    /// revision digits as another version component — `1.2.3_1` is a rebuild of
    /// `1.2.3`, not version `1.2.3.1`.
    private static func components(of version: String) -> (numbers: [Int], suffix: String) {
        var numbers: [Int] = []
        var current = ""
        var suffix = ""
        var index = version.startIndex

        while index < version.endIndex {
            let character = version[index]
            if character.isNumber {
                current.append(character)
            } else if character == "." {
                numbers.append(Int(current) ?? 0)
                current = ""
            } else {
                // First non-numeric, non-dot character: everything from here is
                // the suffix.
                suffix = String(version[index...])
                break
            }
            index = version.index(after: index)
        }
        if !current.isEmpty { numbers.append(Int(current) ?? 0) }
        // Trim trailing zeroes so 2.0 and 2.0.0 compare equal via the padding
        // above rather than by luck.
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        return (numbers, suffix)
    }
}

// MARK: - Pure: Homebrew output

/// Parses `brew outdated --json=v2`.
///
/// Kept separate from the process launch so the shapes Homebrew emits — a
/// pinned formula, a cask with `installed_versions` as a bare string, an empty
/// result — can be tested without running `brew` or touching the network.
enum HomebrewOutdated {

    struct Package: Equatable, Identifiable {
        let name: String
        let installed: String
        let available: String
        let isCask: Bool
        /// Pinned formulae are excluded from upgrades on purpose — the user
        /// pinned them, and quietly upgrading one is the opposite of what a pin
        /// means.
        let isPinned: Bool

        var id: String { (isCask ? "cask:" : "formula:") + name }
    }

    static func parse(_ data: Data) -> [Package] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var packages: [Package] = []
        for (key, isCask) in [("formulae", false), ("casks", true)] {
            guard let entries = root[key] as? [[String: Any]] else { continue }
            for entry in entries {
                guard let name = entry["name"] as? String, !name.isEmpty else { continue }

                // Formulae give an array; casks have been seen giving both an
                // array and a bare string across Homebrew versions.
                let installed: String
                if let list = entry["installed_versions"] as? [String] {
                    installed = list.last ?? ""
                } else if let single = entry["installed_versions"] as? String {
                    installed = single
                } else {
                    continue
                }

                guard let available = entry["current_version"] as? String,
                      !installed.isEmpty, !available.isEmpty
                else { continue }

                // Only report a real upgrade. `brew outdated` occasionally
                // lists something whose version has not moved (a rebuild), and
                // showing "1.2.3 → 1.2.3" reads as a bug.
                guard VersionComparator.isUpgrade(installed: installed, available: available)
                else { continue }

                packages.append(Package(
                    name: name, installed: installed, available: available,
                    isCask: isCask, isPinned: (entry["pinned"] as? Bool) ?? false))
            }
        }
        return packages.sorted { $0.name < $1.name }
    }
}

// MARK: - Manager

/// Lists outdated Homebrew packages and out-of-date applications.
///
/// ## Nothing is installed or upgraded without the user asking
///
/// `brew upgrade` changes the system and cannot be undone by dragging a folder
/// back, so this manager only ever *reports*. The upgrade button runs a single
/// named package through Terminal, where the user sees exactly what is
/// happening and can stop it — rather than running it invisibly in the
/// background.
///
/// ## Cost
///
/// Nothing runs unless the user presses Check. `brew outdated` hits the network,
/// which is precisely why it is not on a timer.
@MainActor
final class PackageUpdateManager: ObservableObject {
    static let shared = PackageUpdateManager()

    struct AppUpdate: Identifiable, Equatable {
        let name: String
        let path: String
        let version: String
        var id: String { path }
    }

    @Published private(set) var outdated: [HomebrewOutdated.Package] = []
    @Published private(set) var apps: [AppUpdate] = []
    @Published private(set) var isChecking = false
    @Published private(set) var lastError: String?
    /// Whether Homebrew is installed.
    ///
    /// Resolved at init, not in `check()`. It was set only inside `check()`
    /// at first, so the pane rendered "Homebrew is not installed" on a machine
    /// where it plainly was — a false claim shown before the user had pressed
    /// anything. Two `isExecutableFile` calls cost nothing and can happen here.
    @Published private(set) var brewAvailable = false

    private init() {
        brewAvailable = Self.brewPath != nil
    }

    /// Where Homebrew lives. Apple Silicon puts it in `/opt/homebrew`; the
    /// Intel path is checked too so this does not silently do nothing on a
    /// machine that has it elsewhere.
    nonisolated private static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    /// `nonisolated` because the detached scan task needs it and this is a pure
    /// filesystem check over two constant paths — no shared mutable state, so
    /// main-actor isolation would buy nothing and only force a hop.
    nonisolated private static var brewPath: String? {
        brewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func check() async {
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        // Re-resolve: Homebrew can be installed while the app is running.
        brewAvailable = Self.brewPath != nil
        async let brewTask = Self.fetchOutdated()
        async let appTask = Self.scanApplications()

        let (packages, applications) = await (brewTask, appTask)
        outdated = packages
        apps = applications
        if brewAvailable && packages.isEmpty && applications.isEmpty {
            lastError = nil
        }
    }

    /// Runs `brew outdated --json=v2` off the main actor.
    nonisolated private static func fetchOutdated() async -> [HomebrewOutdated.Package] {
        guard let brew = brewPath else { return [] }
        return await Task.detached(priority: .utility) { () -> [HomebrewOutdated.Package] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["outdated", "--json=v2"]
            // Homebrew is chatty on stderr about analytics and taps; keeping it
            // separate stops that ending up in the JSON parse.
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            // A clean environment, or brew inherits whatever this process has.
            process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                                   "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"]

            guard (try? process.run()) != nil else { return [] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return HomebrewOutdated.parse(data)
        }.value
    }

    /// Applications that publish a Sparkle feed — the ones that can plausibly
    /// self-update. Apps from the App Store update through it and are not
    /// listed here, because telling someone an App Store app is outdated when
    /// they cannot act on it from here is noise.
    nonisolated private static func scanApplications() async -> [AppUpdate] {
        await Task.detached(priority: .utility) { () -> [AppUpdate] in
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(atPath: "/Applications")
            else { return [] }

            var found: [AppUpdate] = []
            for entry in entries where entry.hasSuffix(".app") {
                let path = "/Applications/" + entry
                guard let bundle = Bundle(path: path),
                      let info = bundle.infoDictionary,
                      info["SUFeedURL"] != nil,
                      // App Store receipts mean the App Store owns updates.
                      !fm.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")
                else { continue }

                let version = (info["CFBundleShortVersionString"] as? String)
                    ?? (info["CFBundleVersion"] as? String) ?? "—"
                found.append(AppUpdate(
                    name: entry.replacingOccurrences(of: ".app", with: ""),
                    path: path, version: version))
            }
            return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }

    /// Opens Terminal on a `brew upgrade` for one package.
    ///
    /// Deliberately visible rather than silent: an upgrade can replace a tool
    /// the user is mid-way through using, and it can prompt. Running it where
    /// they can see and interrupt it is the right trade for a background app.
    func upgradeInTerminal(_ package: HomebrewOutdated.Package) {
        guard let brew = Self.brewPath, !package.isPinned else { return }
        let command = "\(brew) upgrade \(package.isCask ? "--cask " : "")\(package.name)"
        let script = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { lastError = "Could not open Terminal: \(error)" }
    }
}
