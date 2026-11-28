// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Fractional wheel ticks are owned by the current linear-scroll session.
final class LinearScrollCarry {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var vertical: Double = 0
    private var horizontal: Double = 0

    var generation: UInt64 { lock.withLock { revision } }

    func reset() {
        lock.withLock {
            revision &+= 1
            vertical = 0
            horizontal = 0
        }
    }

    func reduce(vertical: ScrollWheelAxisDelta, horizontal: ScrollWheelAxisDelta,
                isContinuous: Bool, linesPerNotch: Int, generation: UInt64)
        -> (ScrollWheelAxisDelta, ScrollWheelAxisDelta)? {
        lock.withLock {
            guard generation == revision else { return nil }
            let first = ScrollWheelSupport.linearDelta(
                vertical, isContinuous: isContinuous, linesPerNotch: linesPerNotch, carry: self.vertical)
            let second = ScrollWheelSupport.linearDelta(
                horizontal, isContinuous: isContinuous, linesPerNotch: linesPerNotch, carry: self.horizontal)
            self.vertical = first.carry
            self.horizontal = second.carry
            return (first.delta, second.delta)
        }
    }
}

/// Retire the carry synchronously when the preference is written. SwiftUI and
/// main-queue reconciliation can otherwise see only the final value of a quick
/// off/on pair while an independent direction feature still owns the tap.
final class LinearScrollPreferenceObserver: NSObject {
    private let defaults: UserDefaults
    private let key: String
    private let onDisable: () -> Void

    init(defaults: UserDefaults, key: String, onDisable: @escaping () -> Void) {
        self.defaults = defaults
        self.key = key
        self.onDisable = onDisable
        super.init()
        defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }

    deinit {
        defaults.removeObserver(self, forKeyPath: key)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == key, (change?[.newKey] as? NSNumber)?.boolValue != true else { return }
        onDisable()
    }
}
