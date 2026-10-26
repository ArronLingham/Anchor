import Foundation

/// Owns a lazily created feature service, rather than keeping it alive forever.
/// A weak reference lets a still-visible editor reuse its service after a quick
/// disable/re-enable, without creating two competing engines.
final class FeatureServiceSlot<Service: AnyObject> {
    let name: String
    private let lock = NSRecursiveLock()
    private let isNeeded: () -> Bool
    private let make: () -> Service
    private let onDisable: (Service) -> Bool
    private var owned: Service?
    private weak var surviving: Service?

    init(_ owners: Set<AppFeature>, requiring parent: AppFeature? = nil,
         name: String = String(reflecting: Service.self),
         isNeeded: (() -> Bool)? = nil,
         make: @escaping () -> Service,
         onDisable: @escaping (Service) -> Bool = { _ in true }) {
        self.name = name
        self.isNeeded = isNeeded ?? {
            (parent?.isAvailable ?? true) && owners.contains(where: \.isAvailable)
        }
        self.make = make
        self.onDisable = onDisable
        FeatureServicePool.shared.register(self)
    }

    var value: Service {
        lock.lock(); defer { lock.unlock() }
        if let value = owned { return value }
        let value = surviving ?? make()
        owned = value
        surviving = value
        return value
    }

    /// Read-only inspection and shutdown must not construct a disabled engine.
    var existing: Service? {
        lock.lock(); defer { lock.unlock() }
        return owned ?? surviving
    }

    func releaseIfUnused() {
        lock.lock(); defer { lock.unlock() }
        guard !isNeeded(), let value = owned else { return }
        guard onDisable(value) else { return }
        owned = nil
    }

    var hasRetainedDisabledInstance: Bool {
        lock.lock(); defer { lock.unlock() }
        return !isNeeded() && surviving != nil
    }
}

/// Contains closures holding weak slots, never a service. Changes are driven
/// by feature switches, with no timer or polling work.
final class FeatureServicePool {
    static let shared = FeatureServicePool()
    private struct Entry {
        let release: () -> Void
        let retained: () -> Bool
        let exists: () -> Bool
    }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func register<Service>(_ slot: FeatureServiceSlot<Service>) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(release: { [weak slot] in slot?.releaseIfUnused() },
                             retained: { [weak slot] in slot?.hasRetainedDisabledInstance ?? false },
                             exists: { [weak slot] in slot != nil }))
    }

    private func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { !$0.exists() }
        return entries
    }

    func releaseUnused() {
        // A shutdown may release a dependent service too. Snapshotting outside
        // the lock makes that safe without serializing unrelated factories.
        for entry in snapshot() { entry.release() }
    }

    var needsRestartToRelease: Bool { snapshot().contains { $0.retained() } }
}
