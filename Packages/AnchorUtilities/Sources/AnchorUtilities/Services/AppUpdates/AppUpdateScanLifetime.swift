// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Atoll Contributors

import Foundation

/// Owns only the read-only work belonging to one App Updates scan.
/// Starting and cancellation are serialized so a queued source cannot start
/// after the scan has been cancelled, even during a rapid off/on cycle.
final class AppUpdateScanLifetime {
    private let lock = NSLock()
    private var active = true
    private var cancellationActions: [UUID: () -> Void] = [:]
    let commandCancellation = BoundedProcessCancellation()

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

    @discardableResult
    func start(_ operation: (UUID) -> (() -> Void)?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        let id = UUID()
        if let cancel = operation(id) { cancellationActions[id] = cancel }
        return true
    }

    func finishRequest(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        cancellationActions.removeValue(forKey: id)
    }

    @discardableResult
    func whileActive(_ operation: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        operation()
        return true
    }

    func cancel() {
        lock.lock()
        guard active else { lock.unlock(); return }
        commandCancellation.cancel()
        active = false
        let actions = Array(cancellationActions.values)
        cancellationActions.removeAll()
        lock.unlock()
        actions.forEach { $0() }
    }

    /// Releases completed request handles without cancelling unrelated work.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        active = false
        cancellationActions.removeAll()
    }
}

/// Starts one bounded group at a time. A cancellation while a group is in
/// flight finishes that group but never starts the next one.
enum AppUpdateBatchScheduler {
    static func run<Item>(_ items: [Item], batchSize: Int,
                          lifetime: AppUpdateScanLifetime, queue: DispatchQueue,
                          beforeDeadline: @escaping () -> Bool,
                          start: @escaping (Item, @escaping () -> Void) -> Void,
                          completion: @escaping (Int) -> Void) {
        precondition(batchSize > 0)
        func batch(_ index: Int) {
            guard lifetime.isActive, index < items.count, beforeDeadline() else {
                completion(index)
                return
            }
            let end = min(index + batchSize, items.count)
            let group = DispatchGroup()
            for item in items[index..<end] {
                group.enter()
                start(item) { group.leave() }
            }
            group.notify(queue: queue) { batch(end) }
        }
        batch(0)
    }
}
