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

// MARK: - Pure formatting

/// Renders a stats sample as menu bar text.
///
/// Pure and separated from the status item because the whole difficulty here is
/// *width*. The menu bar is shared with every other app, and a readout whose
/// width changes with its value makes everything to its left jitter on every
/// sample. Every format below is fixed-width for its type, and that is the
/// property the tests pin.
enum MenuBarReadoutFormatter {

    /// A percentage, always four characters: `  5%`, ` 42%`, `100%`.
    ///
    /// Padded rather than trimmed. `5%` and `100%` differ by two characters,
    /// and in a proportional menu bar font that is a visible shove of every
    /// icon to the left of it, once a second, forever.
    static func percent(_ value: Double) -> String {
        // NaN has no ordering, so it must be caught before the clamp — but
        // the infinities do, and clamping them is more honest than flattening
        // both to zero: +infinity is a value above the range, not an absent one.
        guard !value.isNaN else { return "  0%" }
        let clamped = max(0, min(100, value))
        return String(format: "%3.0f%%", clamped)
    }

    /// A throughput rate, always six characters wide: `  1.2M`, ` 940K`.
    ///
    /// Units step at 1000 rather than 1024 — network rates are quoted decimally
    /// everywhere else, and a readout that disagrees with the router's is worse
    /// than one that is imprecise.
    static func rate(_ bytesPerSecond: Double) -> String {
        let value = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        switch value {
        case 0..<1_000:
            return String(format: "%4.0fB", value)
        case 1_000..<1_000_000:
            return String(format: "%4.0fK", value / 1_000)
        case 1_000_000..<1_000_000_000:
            // One decimal below 10 MB/s, none above, so the width never grows.
            let mb = value / 1_000_000
            return mb < 10 ? String(format: "%4.1fM", mb) : String(format: "%4.0fM", mb)
        default:
            let gb = value / 1_000_000_000
            return gb < 10 ? String(format: "%4.1fG", gb) : String(format: "%4.0fG", gb)
        }
    }

    /// The whole readout, from whichever parts are switched on.
    ///
    /// Returns nil when nothing is enabled, so the caller removes the status
    /// item rather than showing an empty one — an invisible status item still
    /// occupies menu bar width, which is the scarcest space on the screen.
    static func line(cpu: Double?, memory: Double?,
                     netIn: Double?, netOut: Double?) -> String? {
        var parts: [String] = []
        if let cpu { parts.append("CPU \(percent(cpu))") }
        if let memory { parts.append("RAM \(percent(memory))") }
        if let netIn, let netOut {
            parts.append("\u{2193}\(rate(netIn)) \u{2191}\(rate(netOut))")
        } else if let netIn {
            parts.append("\u{2193}\(rate(netIn))")
        } else if let netOut {
            parts.append("\u{2191}\(rate(netOut))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}

// MARK: - Manager

/// A live CPU / memory / network readout in the menu bar.
///
/// ## Cost
///
/// This is the one feature in the app that deliberately holds a periodic
/// sampler open: a live readout is the whole point, so `SystemStatsManager` is
/// `acquire()`d while the readout is visible and `release()`d the moment it is
/// switched off. That is the existing reference-counted pattern, so turning
/// this off returns the machine to exactly the cost it had before — and with
/// the readout off, nothing samples at all.
///
/// The sampler is also released while the display sleeps, via the same
/// `SystemActivityGate` every other poller uses.
@MainActor
final class MenuBarReadoutManager {
    static let shared = MenuBarReadoutManager()

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var statsCancellable: AnyCancellable?
    private var holdsSampler = false
    private var started = false

    /// The font is monospaced-digit rather than the system default, because a
    /// proportional `1` is narrower than a `0` — so even fixed-character-count
    /// text changes width as the digits change.
    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.smallSystemFontSize, weight: .regular)

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        for key in [Defaults.Keys.menuBarShowCPU, Defaults.Keys.menuBarShowMemory,
                    Defaults.Keys.menuBarShowNetwork] {
            Defaults.publisher(key)
                .sink { [weak self] _ in Task { @MainActor in self?.sync() } }
                .store(in: &cancellables)
        }

        SystemActivityGate.shared.$shouldSuspendBackgroundWork
            .sink { [weak self] _ in Task { @MainActor in self?.sync() } }
            .store(in: &cancellables)

        sync()
    }

    private var anyEnabled: Bool {
        Defaults[.menuBarShowCPU] || Defaults[.menuBarShowMemory] || Defaults[.menuBarShowNetwork]
    }

    private func sync() {
        let wanted = anyEnabled && !SystemActivityGate.shared.shouldSuspendBackgroundWork
        wanted ? install() : remove()
    }

    private func install() {
        if statusItem == nil {
            // Variable length: the *text* is fixed-width, but which parts are
            // shown is not, so the item itself must size to its content.
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.font = Self.font
            item.button?.title = ""
            item.behavior = .removalAllowed
            // Persists the user's chosen position across launches, like every
            // other status item. Do not change this string — it would move an
            // existing user's item back to the default position.
            item.autosaveName = "AnchorMenuBarReadout"
            statusItem = item
        }
        if !holdsSampler {
            SystemStatsManager.shared.acquire()
            holdsSampler = true
        }
        statsCancellable = SystemStatsManager.shared.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in
                MainActor.assumeIsolated { self?.render(sample) }
            }
    }

    private func remove() {
        statsCancellable = nil
        if holdsSampler {
            SystemStatsManager.shared.release()
            holdsSampler = false
        }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func render(_ sample: SystemStatsManager.Sample) {
        guard let button = statusItem?.button else { return }
        let text = MenuBarReadoutFormatter.line(
            cpu: Defaults[.menuBarShowCPU] ? sample.cpuPercent : nil,
            memory: Defaults[.menuBarShowMemory] ? sample.memoryPercent : nil,
            netIn: Defaults[.menuBarShowNetwork] ? sample.networkInBytesPerSecond : nil,
            netOut: Defaults[.menuBarShowNetwork] ? sample.networkOutBytesPerSecond : nil)

        guard let text else { remove(); return }
        button.attributedTitle = NSAttributedString(
            string: text, attributes: [.font: Self.font])
    }
}
