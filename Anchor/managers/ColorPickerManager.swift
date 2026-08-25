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
import Defaults
import Foundation

/// Screen colour picker. Category 9.
///
/// `NSColorSampler` is the system eyedropper — AppKit runs the magnifier and
/// the capture, so there is no screen-recording grant to ask for and nothing of
/// ours runs until the user invokes it. Idle cost is zero by construction.
///
/// The colour model is `PickedColor`, which survived Phase 1's removal of the
/// old picker panel and already carries all eight output formats.
@MainActor
final class ColorPickerManager: ObservableObject {
    static let shared = ColorPickerManager()

    /// Most recent first.
    @Published private(set) var history: [PickedColor] = []

    private let maxHistory = 24

    /// Held for the duration of a pick — a local would be released before the
    /// completion handler fires.
    private var sampler: NSColorSampler?

    private var storeURL: URL {
        AppSupportDirectory.root.appendingPathComponent("color-history.json")
    }

    private init() {
        DispatchQueue.main.async { [weak self] in self?.load() }
    }

    /// Opens the system eyedropper. The picked colour goes to the clipboard in
    /// the configured format and into history.
    func pick() {
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { [weak self] color in
            Task { @MainActor in
                defer { self?.sampler = nil }
                guard let color, let self else { return }
                self.record(color)
            }
        }
    }

    private func record(_ color: NSColor) {
        // NSColorSampler does not report where the user clicked, and nothing
        // here uses the point.
        let picked = PickedColor(nsColor: color, point: .zero)
        copy(picked)

        // A repeat pick of the same colour moves to the front rather than
        // filling the strip with duplicates.
        history.removeAll { $0.hexString == picked.hexString }
        history.insert(picked, at: 0)
        if history.count > maxHistory {
            history.removeLast(history.count - maxHistory)
        }
        save()
    }

    /// Copies in the user's configured format, falling back to hex if that
    /// format name is ever removed from `PickedColor`.
    func copy(_ picked: PickedColor) {
        let wanted = Defaults[.colorPickerFormat]
        let value = picked.allFormats.first { $0.name == wanted }?.copyValue ?? picked.hexString
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    func clearHistory() {
        history = []
        save()
    }

    private func save() {
        let snapshot = history
        let url = storeURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([PickedColor].self, from: data)
        else { return }
        history = decoded
    }

    /// Format names offered in Settings, taken from the model so the two
    /// cannot drift.
    static var availableFormats: [String] {
        PickedColor(red: 0, green: 0, blue: 0, point: .zero).allFormats.map(\.name)
    }
}
