// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Observes only the switches that start or stop WhatsApp background work.
/// Capture each delivered change before dispatching instead of reading only
/// the final value when a quick off/on has already occurred.
final class WhatsAppPreferenceObserver: NSObject {
    static let keys = [DefaultsKey.whatsAppDownloadsEnabled,
                       DefaultsKey.whatsAppDownloadsAutomaticEnabled,
                       DefaultsKey.whatsAppOrganizerEnabled,
                       DefaultsKey.whatsAppDownloadsAccessConfirmed]

    private let defaults: UserDefaults
    private let onChange: (String, Bool) -> Void
    private var values: [String: Bool]

    init(defaults: UserDefaults, onChange: @escaping (String, Bool) -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        self.values = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, defaults.bool(forKey: $0)) })
        super.init()
        for key in Self.keys { defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil) }
    }

    deinit {
        for key in Self.keys { defaults.removeObserver(self, forKeyPath: key) }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let key = keyPath, Self.keys.contains(key) else { return }
        let enabled = (change?[.newKey] as? NSNumber)?.boolValue ?? defaults.bool(forKey: key)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.values[key] != enabled else { return }
            self.values[key] = enabled
            self.onChange(key, enabled)
        }
    }
}
