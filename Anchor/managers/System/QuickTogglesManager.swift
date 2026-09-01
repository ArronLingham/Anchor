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

/// One-shot system actions — light/dark mode, hidden files, ejecting disks and
/// so on.
///
/// ## Cost
///
/// None. This is a namespace of functions with no stored state, no observers
/// and no timers; nothing here runs until the user picks an action from the
/// launcher.
///
/// ## Why several of these are AppleScript
///
/// macOS exposes no public API for toggling the system appearance or emptying
/// the Trash, and the private routes are worse than a scripting bridge: they
/// change between releases and can fail silently. `System Events` and `Finder`
/// have supported these verbs for many releases, and a scripting error is at
/// least a *visible* failure that can be reported back.
///
/// The first use of each will make macOS ask for Automation permission for the
/// target app. That prompt is the user's decision to make, and a denial is
/// surfaced rather than swallowed.
@MainActor
enum QuickToggles {
    /// What happened, so callers can tell the user rather than failing silently.
    enum Outcome {
        case success(String)
        case failure(String)
    }

    // MARK: - Appearance

    static func toggleDarkMode() -> Outcome {
        runAppleScript(
            """
            tell application "System Events"
                tell appearance preferences
                    set dark mode to not dark mode
                    return (dark mode as text)
                end tell
            end tell
            """,
            success: { $0 == "true" ? "Dark mode on" : "Dark mode off" },
            failureLabel: "Could not change appearance")
    }

    // MARK: - Finder

    static func toggleHiddenFiles() -> Outcome {
        // Read the current value first: `defaults` has no toggle, and reading
        // the wrong default (or assuming false) makes the first use a no-op.
        let shown = UserDefaults(suiteName: "com.apple.finder")?
            .bool(forKey: "AppleShowAllFiles") ?? false
        let next = !shown

        let write = Process()
        write.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        write.arguments = ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", next ? "true" : "false"]
        do {
            try write.run()
            write.waitUntilExit()
        } catch {
            return .failure("Could not change Finder settings")
        }

        // Finder only re-reads that default on relaunch. `killall Finder` is
        // what every recipe for this uses; Finder restarts itself immediately.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        relaunch.arguments = ["Finder"]
        relaunch.standardError = Pipe()
        try? relaunch.run()
        relaunch.waitUntilExit()

        return .success(next ? "Hidden files shown" : "Hidden files hidden")
    }

    static func toggleDesktopIcons() -> Outcome {
        let shown = UserDefaults(suiteName: "com.apple.finder")?
            .object(forKey: "CreateDesktop") as? Bool ?? true
        let next = !shown

        let write = Process()
        write.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        write.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", next ? "true" : "false"]
        do {
            try write.run()
            write.waitUntilExit()
        } catch {
            return .failure("Could not change Finder settings")
        }

        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        relaunch.arguments = ["Finder"]
        relaunch.standardError = Pipe()
        try? relaunch.run()
        relaunch.waitUntilExit()

        return .success(next ? "Desktop icons shown" : "Desktop icons hidden")
    }

    static func emptyTrash() -> Outcome {
        runAppleScript(
            """
            tell application "Finder"
                empty the trash
                return "ok"
            end tell
            """,
            success: { _ in "Trash emptied" },
            failureLabel: "Could not empty the Trash")
    }

    /// Ejects every ejectable volume.
    ///
    /// Deliberately not `Finder`'s "eject every disk", which also tries to
    /// unmount things it should not. This asks the workspace for each mounted
    /// volume and only ejects those macOS reports as removable or ejectable,
    /// so an internal disk or a network home directory is left alone.
    static func ejectAllDisks() -> Outcome {
        let workspace = NSWorkspace.shared
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
        else { return .failure("Could not list volumes") }

        var ejected = 0
        var failed: [String] = []
        for url in volumes {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let removable = (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false)
            let internalDisk = values.volumeIsInternal ?? false
            guard removable, !internalDisk else { continue }

            do {
                try workspace.unmountAndEjectDevice(at: url)
                ejected += 1
            } catch {
                failed.append(url.lastPathComponent)
            }
        }

        if !failed.isEmpty {
            return .failure("Could not eject \(failed.joined(separator: ", "))")
        }
        if ejected == 0 {
            return .success("No removable disks mounted")
        }
        return .success("Ejected \(ejected) disk\(ejected == 1 ? "" : "s")")
    }

    // MARK: - Screen

    static func lockScreen() -> Outcome {
        // The keychain-lock route (`SACLockScreenImmediate`) needs a private
        // framework. Sending the same key combination macOS itself binds is
        // both public and exactly what the user would press.
        let source = CGEventSource(stateID: .combinedSessionState)
        let qKey: CGKeyCode = 0x0C  // kVK_ANSI_Q
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: qKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: qKey, keyDown: false)
        else { return .failure("Could not lock the screen") }

        down.flags = [.maskCommand, .maskControl]
        up.flags = [.maskCommand, .maskControl]
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .success("Locking screen")
    }

    // MARK: - Helpers

    private static func runAppleScript(
        _ source: String,
        success: (String) -> String,
        failureLabel: String
    ) -> Outcome {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(failureLabel)
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743 is "not authorised to send Apple events" — the user either
            // has not been asked yet or declined. Saying so is far more useful
            // than a generic failure, because the fix is in System Settings.
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                return .failure("\(failureLabel) — allow Anchor to control this app in System Settings › Privacy & Security › Automation")
            }
            return .failure(failureLabel)
        }
        return .success(success(result.stringValue ?? ""))
    }
}
