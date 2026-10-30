import AppKit
import Combine
import CoreFoundation
import Darwin

/// The Dock's own interface, also used by macOS Desktop & Dock settings.
/// These symbols are undocumented: resolve them at runtime and verify writes.
enum NativeDockSpaces {
    private typealias CopyPreferences = @convention(c) (CFArray, UnsafeMutablePointer<Unmanaged<CFDictionary>?>, UnsafeMutablePointer<Unmanaged<CFError>?>) -> Void
    private typealias SetPreferences = @convention(c) (CFDictionary) -> Void
    private static let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let copy: CopyPreferences? = library.flatMap { dlsym($0, "CoreDockCopyPreferences") }.map { unsafeBitCast($0, to: CopyPreferences.self) }
    private static let set: SetPreferences? = library.flatMap { dlsym($0, "CoreDockSetPreferences") }.map { unsafeBitCast($0, to: SetPreferences.self) }
    private static let key = "autoReorderSpaces"
    static let notification = Notification.Name("com.apple.dock.prefchanged")

    static func read() -> Bool? {
        guard let copy, set != nil else { return nil }
        var result: Unmanaged<CFDictionary>?
        var error: Unmanaged<CFError>?
        copy([key] as CFArray, &result, &error)
        if let error { _ = error.takeRetainedValue(); return nil }
        guard let dictionary = result?.takeRetainedValue() as? [String: Any],
              let value = dictionary[key] as? NSNumber,
              value.doubleValue == 0 || value.doubleValue == 1 else { return nil }
        return value.boolValue
    }

    static func isManaged() -> Bool {
        CFPreferencesAppValueIsForced("mru-spaces" as CFString, "com.apple.dock" as CFString)
    }

    static func write(_ rearrange: Bool) -> Bool {
        guard !isManaged(), let set else { return false }
        set([key: rearrange] as CFDictionary)
        guard read() == rearrange else { return false }
        DistributedNotificationCenter.default().postNotificationName(notification, object: nil, userInfo: nil, deliverImmediately: true)
        return true
    }
}

struct NativeSpacesSystem {
    var read: () -> Bool?
    var write: (Bool) -> Bool
    var managed: () -> Bool
    static let live = NativeSpacesSystem(read: NativeDockSpaces.read, write: NativeDockSpaces.write,
                                         managed: { NativeDockSpaces.isManaged() || LegacySpacesOrderRecovery.hasPendingRestore })
}

/// One observed value for both the settings page and quick panel. No timer:
/// the Dock notification and app activation refresh changes made elsewhere.
final class NativeSpacesOrder: ObservableObject {
    static let shared = NativeSpacesOrder(system: .live)
    @Published private(set) var fixedOrder: Bool?
    @Published private(set) var isApplying = false
    @Published private(set) var isManaged = false
    @Published private(set) var error: String?
    private let system: NativeSpacesSystem
    private let queue = DispatchQueue(label: "com.anchor.native-spaces")
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var dockObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var preferenceWatcher: DispatchSourceFileSystemObject?
    private let preferencePath: String
    private let migrate: () -> Void
    private var refreshAfterApplying = false // main thread only

    init(system: NativeSpacesSystem, preferencePath: String = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist",
         migrate: @escaping () -> Void = { LegacySpacesOrderRecovery.recoverIfNeeded() }) {
        self.system = system
        self.preferencePath = preferencePath
        self.migrate = migrate
    }

    private func nextGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    private func isCurrent(_ request: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == request
    }

    func start() {
        migrate()
        if dockObserver == nil {
            fixedOrder = nil
            isApplying = false
            refreshAfterApplying = false
            dockObserver = DistributedNotificationCenter.default().addObserver(forName: NativeDockSpaces.notification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
            activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
            watchPreferences()
        }
        refresh()
    }

    func stop() {
        let request = nextGeneration()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(request) else { return }
            self.isApplying = false
            self.refreshAfterApplying = false
        }
        if let dockObserver { DistributedNotificationCenter.default().removeObserver(dockObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        dockObserver = nil
        activationObserver = nil
        preferenceWatcher?.cancel()
        preferenceWatcher = nil
    }

    /// macOS does not broadcast the Dock notification for every change made
    /// in System Settings. Watch its preference file instead of polling; atomic
    /// replacements require a new descriptor for the new file.
    private func watchPreferences() {
        preferenceWatcher?.cancel()
        preferenceWatcher = nil
        let descriptor = open(preferencePath, O_EVTONLY)
        guard descriptor >= 0 else { return } // activation still refreshes
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in
            guard let self, let source = self.preferenceWatcher else { return }
            let changed = source.data
            self.refresh()
            if changed.contains(.rename) || changed.contains(.delete) { self.watchPreferences() }
        }
        preferenceWatcher = source
        source.resume()
    }

    func refresh() {
        // Do not let a notification cancel an in-flight write. Re-read after
        // it settles, including when another process changed the Dock too.
        if isApplying { refreshAfterApplying = true; return }
        perform(desiredFixedOrder: nil)
    }
    func setFixedOrder(_ fixed: Bool) {
        // Mark the write before yielding the main thread, so a simultaneous
        // notification cannot replace it with a read-only refresh.
        isApplying = true
        error = nil
        perform(desiredFixedOrder: fixed)
    }

    private func perform(desiredFixedOrder: Bool?) {
        let request = nextGeneration()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(request) else { return }
            let applying = desiredFixedOrder != nil
            if self.isApplying != applying { self.isApplying = applying }
            if desiredFixedOrder != nil { self.error = nil }
        }
        queue.async { [self] in
            guard isCurrent(request) else { return }
            let managed = system.managed()
            let success = desiredFixedOrder.map { !managed && system.write(!$0) } ?? true
            let current = system.read().map { !$0 }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(request) else { return }
                self.fixedOrder = current
                self.isManaged = managed
                self.isApplying = false
                if !success { self.error = "macOS could not apply this change." }
                else if current == nil { self.error = "Could not read the macOS Spaces setting." }
                else if desiredFixedOrder != nil || self.error == "Could not read the macOS Spaces setting." { self.error = nil }
                if self.refreshAfterApplying {
                    self.refreshAfterApplying = false
                    self.refresh()
                }
            }
        }
    }
}
