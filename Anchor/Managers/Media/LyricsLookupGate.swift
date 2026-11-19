/*
 * Anchor
 * Copyright (C) 2026 Atoll Contributors
 * SPDX-License-Identifier: GNU GPL-3.0-or-later
 */

import Foundation

/// Preference notifications can arrive before their main-queue UI update.
/// Track both the enabled interval and the individual lookup so an old result
/// cannot overwrite a newer request for the same track.
final class LyricsLookupGate {
    struct Ticket: Equatable {
        fileprivate let epoch: UUID
        fileprivate let request: UUID
    }

    private let lock = NSLock()
    private var enabled: Bool
    private var epoch = UUID()
    private var activeRequest: UUID?

    init(enabled: Bool) { self.enabled = enabled }

    @discardableResult
    func update(enabled newValue: Bool) -> UUID {
        lock.lock(); defer { lock.unlock() }
        if enabled != newValue {
            enabled = newValue
            epoch = UUID()
            activeRequest = nil
        }
        return epoch
    }

    func acceptsEpoch(_ candidate: UUID, currentlyEnabled: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return epoch == candidate && enabled == currentlyEnabled
    }

    func permitsLookup(currentlyEnabled: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && currentlyEnabled
    }

    func begin(currentlyEnabled: Bool) -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        guard enabled && currentlyEnabled else { return nil }
        let request = UUID()
        activeRequest = request
        return Ticket(epoch: epoch, request: request)
    }

    func accepts(_ ticket: Ticket, currentlyEnabled: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && currentlyEnabled && epoch == ticket.epoch && activeRequest == ticket.request
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        activeRequest = nil
    }

    func finish(_ ticket: Ticket, currentlyEnabled: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled && currentlyEnabled && epoch == ticket.epoch && activeRequest == ticket.request else { return false }
        activeRequest = nil
        return true
    }
}
