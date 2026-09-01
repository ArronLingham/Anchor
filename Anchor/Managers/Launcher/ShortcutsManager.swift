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

// MARK: - Pure: parsing and safety

/// Reads `shortcuts list` output and decides what is safe to run.
///
/// Pure, and the safety half matters more than the parsing half: a shortcut
/// name is **user-controlled text that this code turns into a process
/// invocation**. Anyone who can create a shortcut chooses that string.
enum ShortcutsCatalog {

    /// One shortcut name per line. Blank lines and surrounding whitespace are
    /// dropped; everything else is kept verbatim, including spaces, emoji and
    /// punctuation, because those are all legal in a shortcut name and
    /// "sanitising" them would simply fail to find the shortcut.
    static func parse(_ output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whether a name may be passed to `shortcuts run`.
    ///
    /// ## This is not shell-escaping, and must never become it
    ///
    /// The name is handed to `Process.arguments` as a single argv element, so
    /// there is no shell to escape *for*: `;`, `$(…)`, backticks and quotes are
    /// all inert. That is the actual defence, and it is why this function is
    /// deliberately permissive — a shortcut genuinely called `Backup; now` must
    /// still run.
    ///
    /// What is rejected is only what cannot be a real argv element or cannot be
    /// a real shortcut: an empty name, and one containing a NUL (which would
    /// truncate the argument) or a newline (which cannot appear in a name and
    /// indicates the parse went wrong).
    static func isRunnable(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard !name.contains("\0") else { return false }
        guard !name.contains("\n"), !name.contains("\r") else { return false }
        // A name that is only whitespace is a parse artefact, not a shortcut.
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return true
    }

    /// The argv for running `name`. Never a shell string.
    ///
    /// Returned as an array precisely so that no caller can be tempted to
    /// interpolate it into a command line.
    static func runArguments(for name: String) -> [String]? {
        guard isRunnable(name) else { return nil }
        return ["run", name]
    }
}

// MARK: - Manager

/// Runs Apple Shortcuts from the launcher.
///
/// ## Cost
///
/// The list is fetched once on first use and then only when the user asks for a
/// refresh. `shortcuts list` spawns a process, so it is not something to do on
/// a timer or on every keystroke — the launcher searches the cached names.
@MainActor
final class AppleShortcutsManager: ObservableObject {
    static let shared = AppleShortcutsManager()

    @Published private(set) var names: [String] = []
    @Published private(set) var isLoading = false
    /// Nil until a load has been attempted.
    @Published private(set) var isAvailable: Bool?

    private var hasLoaded = false
    private init() {}

    /// `nonisolated`: a constant path, read from the detached list task.
    nonisolated private static let binary = "/usr/bin/shortcuts"

    /// Loads the list if it has not been loaded yet.
    func loadIfNeeded() {
        guard !hasLoaded, !isLoading else { return }
        Task { await refresh() }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }

        guard FileManager.default.isExecutableFile(atPath: Self.binary) else {
            isAvailable = false
            names = []
            return
        }

        let output = await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.binary)
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }.value

        guard let output else {
            isAvailable = false
            names = []
            return
        }
        isAvailable = true
        names = ShortcutsCatalog.parse(output).filter(ShortcutsCatalog.isRunnable)
    }

    /// Runs a shortcut by name.
    ///
    /// The name goes into `Process.arguments` as one element. There is no
    /// shell anywhere in this path, so a shortcut named `rm -rf /` is just a
    /// shortcut with an odd name — `shortcuts` receives it as a single
    /// argument and looks it up.
    func run(_ name: String) {
        guard let arguments = ShortcutsCatalog.runArguments(for: name),
              FileManager.default.isExecutableFile(atPath: Self.binary)
        else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.binary)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            NSLog("⚠️ AppleShortcuts: could not run \(name): \(error)")
        }
    }

    /// Launcher entries for the cached shortcuts.
    func launcherCommands() -> [LauncherCommand] {
        names.map { name in
            LauncherCommand(
                id: "shortcut." + name,
                title: name,
                subtitle: "Apple Shortcut",
                symbolName: "square.stack.3d.up",
                keywords: ["shortcut", "shortcuts", "workflow", "automation"]
            ) { [weak self] in
                self?.run(name)
            }
        }
    }
}
