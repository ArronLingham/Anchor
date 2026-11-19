/*
 * Anchor
 * Copyright (C) 2026 Atoll Contributors
 * SPDX-License-Identifier: GNU GPL-3.0-or-later
 */

import Foundation

/// Coordinates the SwiftUI views that can supply a TranslationSession.
/// All methods are called on the main thread; the gate is invalidated as soon
/// as preference or lyric notifications arrive, including off the main queue.
final class LyricsTranslationCoordinator {
    struct Request {
        let ticket: LyricsLookupGate.Ticket
        let lines: [String]
    }

    typealias Handler = (Request?) -> Void
    private let gate: LyricsLookupGate
    private var handlers: [UUID: Handler] = [:]
    private var order: [UUID] = []
    private var owner: UUID?
    private var request: Request?
    private var lines: [String] = []
    private var completedLines: [String]?
    private var epoch: UUID?
    private var enabled = false
    var clear: () -> Void = {}
    var setTranslating: (Bool) -> Void = { _ in }

    init(gate: LyricsLookupGate) { self.gate = gate }

    func register(_ id: UUID, handler: @escaping Handler, enabled: Bool, lines: [String]) {
        if handlers[id] == nil { order.append(id) }
        handlers[id] = handler
        reconcile(enabled: enabled, lines: lines)
    }

    func unregister(_ id: UUID, enabled: Bool, lines: [String]) {
        handlers.removeValue(forKey: id)
        order.removeAll { $0 == id }
        if owner == id {
            gate.cancel()
            owner = nil
            request = nil
            setTranslating(false)
        }
        reconcile(enabled: enabled, lines: lines)
    }

    func reconcile(enabled: Bool, lines: [String]) {
        let currentEpoch = gate.update(enabled: enabled)
        let changed = self.enabled != enabled || self.lines != lines || epoch != currentEpoch
        self.enabled = enabled
        self.lines = lines
        epoch = currentEpoch
        if changed {
            cancelRequest()
            completedLines = nil
            clear()
        } else if let request, !gate.accepts(request.ticket, currentlyEnabled: enabled) {
            cancelRequest()
        }
        guard enabled, !lines.isEmpty, completedLines != lines, request == nil,
              let id = order.last, let handler = handlers[id],
              let ticket = gate.begin(currentlyEnabled: enabled) else { return }
        let next = Request(ticket: ticket, lines: lines)
        owner = id
        request = next
        setTranslating(true)
        handler(next)
    }

    func accepts(_ candidate: Request, owner id: UUID, enabled: Bool, lines: [String]) -> Bool {
        owner == id && request?.ticket == candidate.ticket && candidate.lines == lines
            && gate.accepts(candidate.ticket, currentlyEnabled: enabled)
    }

    func finish(_ candidate: Request, owner id: UUID, enabled: Bool, lines: [String], success: Bool) -> Bool {
        guard accepts(candidate, owner: id, enabled: enabled, lines: lines),
              gate.finish(candidate.ticket, currentlyEnabled: enabled) else { return false }
        owner = nil
        request = nil
        completedLines = success ? lines : nil
        setTranslating(false)
        return true
    }

    private func cancelRequest() {
        gate.cancel()
        if let owner { handlers[owner]?(nil) }
        owner = nil
        request = nil
        setTranslating(false)
    }
}
