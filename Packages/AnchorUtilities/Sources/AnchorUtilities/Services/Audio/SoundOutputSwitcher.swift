// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Carbon.HIToolbox
import Combine
import Foundation

/// Cycles the system output through the devices selected in the mixer panel.
final class SoundOutputSwitcher: ObservableObject {
    private static weak var initializedInstance: SoundOutputSwitcher?
    static let shared: SoundOutputSwitcher = {
        let service = SoundOutputSwitcher()
        initializedInstance = service
        return service
    }()
    static var existing: SoundOutputSwitcher? { initializedInstance }

    @Published private(set) var registrationFailed = false
    @Published private(set) var lastSwitchFailed = false

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var registeredShortcut: GlobalShortcut?
    private let shortcutGate = ClipboardPresentationGate()

    private init() {}

    func syncWithPreferences() {
        UtilityWorkspace.shared.prepareOwnership()
        if Self.switcherWanted { registerHotkey() } else { unregisterHotkey() }
    }

    private static var switcherWanted: Bool {
        AppFeature.soundOutputSwitcher.isAvailable
            && UtilityPreferences.standard.bool(forKey: DefaultsKey.soundOutputSwitcherEnabled)
    }

    func stop() {
        unregisterHotkey()
    }

    func selectedDeviceUIDs() -> [String] {
        Defaults.sanitizedSoundOutputSwitcherDeviceUIDs(
            UtilityPreferences.standard.array(forKey: DefaultsKey.soundOutputSwitcherDeviceUIDs) ?? []
        )
    }

    func setSelectedDeviceUIDs(_ uids: [String]) {
        let sanitized = Defaults.sanitizedSoundOutputSwitcherDeviceUIDs(uids)
        if sanitized.isEmpty {
            UtilityPreferences.standard.removeObject(forKey: DefaultsKey.soundOutputSwitcherDeviceUIDs)
        } else {
            UtilityPreferences.standard.set(sanitized, forKey: DefaultsKey.soundOutputSwitcherDeviceUIDs)
        }
        lastSwitchFailed = false
    }

    private func scheduleSwitch() {
        guard let ticket = shortcutGate.capture(currentlyAvailable: Self.switcherWanted),
              let session = SessionActivity.shared.captureActiveSession() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.shortcutGate.accepts(ticket, currentlyAvailable: Self.switcherWanted),
                  SessionActivity.shared.acceptsSession(session) else { return }
            self.lastSwitchFailed = !AppVolumeMixer.shared.switchToNextSoundOutput(in: self.selectedDeviceUIDs())
        }
    }

    private func registerHotkey() {
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.soundOutputSwitcherShortcut,
                                            fallback: .soundOutputSwitcherDefault)
        if hotKeyRef != nil, registeredShortcut == shortcut { return }
        unregisterHotkey()
        if eventHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                if let event {
                    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &id)
                }
                guard id.signature == 0x5655_534F, id.id == 4
                else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<SoundOutputSwitcher>.fromOpaque(userData).takeUnretainedValue()
                service.scheduleSwitch()
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard status == noErr, eventHandler != nil else {
                unregisterHotkey()
                registrationFailed = true
                return
            }
        }
        let id = EventHotKeyID(signature: 0x5655_534F, id: 4) // 'VUSO'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.carbonKeyCode,
                                         shortcut.carbonModifiers,
                                         id,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
            registeredShortcut = shortcut
            shortcutGate.update(available: true)
            registrationFailed = false
            SystemShortcutTakeover.claim(DefaultsKey.soundOutputSwitcherShortcut, shortcut: shortcut)
        } else {
            unregisterHotkey()
            registrationFailed = true
        }
    }

    /// Lets go of the global key while a shortcut field is listening, so the
    /// user can record the very combination this feature uses. The next
    /// `syncWithPreferences` takes it back.
    func suspendShortcut() { unregisterHotkey() }

    private func unregisterHotkey() {
        shortcutGate.update(available: false)
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            SystemShortcutTakeover.release(DefaultsKey.soundOutputSwitcherShortcut)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        hotKeyRef = nil
        registeredShortcut = nil
        registrationFailed = false
        lastSwitchFailed = false
    }
}
