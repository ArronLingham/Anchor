import AppKit
import CoreFoundation
import SwiftUI

/// Uses WindowManager's own domain rather than an Anchor copy of the switches.
/// Keys are undocumented, so writes are verified and failures remain visible.
enum NativeWindowTilingPreference: String, CaseIterable {
    case edges = "EnableTilingByEdgeDrag"
    case top = "EnableTopTilingByEdgeDrag"
    case option = "EnableTilingOptionAccelerator"

    var title: String {
        switch self {
        case .edges: return "Drag windows to screen edges to tile"
        case .top: return "Drag windows to menu bar to fill screen"
        case .option: return "Hold Option while dragging windows to tile"
        }
    }
}

struct NativeWindowTilingPreferences {
    let domain: String
    init(domain: String = "com.apple.WindowManager") { self.domain = domain }

    func refresh() -> Bool { CFPreferencesAppSynchronize(domain as CFString) }

    func value(_ preference: NativeWindowTilingPreference) -> Bool? {
        guard let value = CFPreferencesCopyAppValue(preference.rawValue as CFString, domain as CFString) else {
            // macOS enables these options by default before a value is saved.
            return true
        }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return (value as! NSNumber).boolValue
    }

    func isManaged(_ preference: NativeWindowTilingPreference) -> Bool {
        CFPreferencesAppValueIsForced(preference.rawValue as CFString, domain as CFString)
    }

    func set(_ preference: NativeWindowTilingPreference, to enabled: Bool) -> Bool {
        guard !isManaged(preference) else { return false }
        CFPreferencesSetValue(preference.rawValue as CFString,
                              enabled ? kCFBooleanTrue : kCFBooleanFalse,
                              domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              refresh() else { return false }
        return value(preference) == enabled
    }
}

/// Shared by original Anchor settings and utility window settings. No timer or
/// duplicate preference: refresh on presentation and return from System Settings.
public struct NativeWindowTilingSettings: View {
    @State private var values: [NativeWindowTilingPreference: Bool] = [:]
    @State private var managed = Set<NativeWindowTilingPreference>()
    @State private var error: String?
    private let preferences = NativeWindowTilingPreferences()
    public init() {}

    public var body: some View {
        ForEach(NativeWindowTilingPreference.allCases, id: \.self) { preference in
            Toggle(preference.title, isOn: Binding(
                get: { values[preference] ?? false },
                set: { enabled in
                    if !preferences.set(preference, to: enabled) {
                        error = "macOS did not accept this change. Check Desktop & Dock settings."
                    } else { error = nil }
                    refresh()
                    WindowLayoutService.existing?.syncWithPreferences()
                }))
                .disabled(values[preference] == nil || managed.contains(preference))
        }
        Text("These are the macOS Desktop & Dock settings. Changes here update macOS directly.")
            .font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        Button("Open Desktop & Dock Settings…") {
            NSWorkspace.shared.open(WindowEdgeSnapSupport.desktopAndDockSettingsURL)
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    private func refresh() {
        guard preferences.refresh() else {
            values = [:]
            error = "Could not read the macOS window tiling settings."
            return
        }
        values = Dictionary(uniqueKeysWithValues: NativeWindowTilingPreference.allCases.compactMap {
            preference in preferences.value(preference).map { (preference, $0) }
        })
        managed = Set(NativeWindowTilingPreference.allCases.filter { preferences.isManaged($0) })
    }
}
