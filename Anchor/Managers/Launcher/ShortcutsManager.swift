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

/// Discovers Apple Shortcuts for Launchpad and runs a selected shortcut.
@MainActor
final class AppleShortcutsManager: ObservableObject {
    static let shared = AppleShortcutsManager()

    @Published private(set) var names: [String] = []
    private var hasLoaded = false
    private var loadingProcess: Process?
    private var catalogID = UUID()
    private var subscriptions = Set<AnyCancellable>()

    private let binary: URL

    init(binary: URL = URL(fileURLWithPath: "/usr/bin/shortcuts")) {
        self.binary = binary
        for key in [Defaults.Key<Bool>.enableLauncher, .enableShortcutsLauncher] {
            Defaults.publisher(key, options: [])
                .sink { [weak self] change in
                    guard !change.newValue else { return }
                    if Thread.isMainThread {
                        MainActor.assumeIsolated { self?.resetCatalog() }
                    } else {
                        DispatchQueue.main.async { self?.resetCatalog() }
                    }
                }
                .store(in: &subscriptions)
        }
    }

    private var isEnabled: Bool {
        Defaults[.enableLauncher] && Defaults[.enableShortcutsLauncher]
    }

    func loadIfNeeded() {
        guard isEnabled, !hasLoaded, loadingProcess == nil else { return }
        let process = makeProcess(arguments: ["list"])
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            hasLoaded = true
            return
        }
        loadingProcess = process

        let reader = Task.detached(priority: .utility) { () -> [String] in
            let data = try? pipe.fileHandleForReading.readToEnd()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let data,
                  let output = String(data: data, encoding: .utf8) else { return [] }
            return ShortcutsCatalog.parse(output).filter(ShortcutsCatalog.isRunnable)
        }

        Task { [weak self] in
            let result = await reader.value
            guard let self, self.loadingProcess === process else { return }
            self.loadingProcess = nil
            guard self.isEnabled else { return }
            self.hasLoaded = true
            self.names = result
        }
    }

    /// Closing Launchpad ends unfinished discovery. A completed catalog can
    /// still be reused when Launchpad next opens.
    func cancelLoading() {
        let process = loadingProcess
        loadingProcess = nil
        if let process, process.isRunning { process.terminate() }
    }

    private func resetCatalog() {
        catalogID = UUID()
        cancelLoading()
        hasLoaded = false
        if !names.isEmpty { names = [] }
    }

    private func makeProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func run(_ name: String, from catalog: UUID) {
        guard isEnabled, catalogID == catalog,
              let arguments = ShortcutsCatalog.runArguments(for: name) else { return }
        do {
            try makeProcess(arguments: arguments).run()
        } catch {
            NSLog("AppleShortcuts: could not run shortcut: \(error)")
        }
    }

    func launcherCommands() -> [LauncherCommand] {
        guard isEnabled else { return [] }
        let catalog = catalogID
        return names.map { name in
            LauncherCommand(
                id: "shortcut." + name,
                title: name,
                subtitle: "Apple Shortcut",
                symbolName: "square.stack.3d.up",
                keywords: ["shortcut", "shortcuts", "workflow", "automation"]
            ) { [weak self] in
                self?.run(name, from: catalog)
            }
        }
    }
}
