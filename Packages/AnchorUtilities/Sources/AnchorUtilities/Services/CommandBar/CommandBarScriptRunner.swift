// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Owns every saved-script process until it actually exits. A normal bar close
/// deliberately leaves those processes alone, but uninstalling Command Bar can
/// still find and terminate work that began in an older presentation.
final class CommandBarScriptExecutionRegistry {
    struct Execution {
        let id: UUID
        let cancellation: BoundedProcessCancellation
    }

    private struct ActiveExecution {
        let key: String
        let cancellation: BoundedProcessCancellation
    }

    private var active: [UUID: ActiveExecution] = [:]
    private var cancellingKeys: Set<String> = []

    func begin(key: String) -> Execution? {
        // Cancellation is asynchronous. Do not start a replacement for the
        // same query until every child from the disabled feature has exited.
        guard !cancellingKeys.contains(key) else { return nil }
        let execution = Execution(id: UUID(), cancellation: BoundedProcessCancellation())
        active[execution.id] = ActiveExecution(key: key, cancellation: execution.cancellation)
        return execution
    }

    /// Returns whether this exit completed disablement cancellation for `key`.
    @discardableResult
    func finish(_ execution: Execution, key: String) -> Bool {
        guard active.removeValue(forKey: execution.id) != nil else { return false }
        guard cancellingKeys.contains(key), !active.values.contains(where: { $0.key == key }) else {
            return false
        }
        cancellingKeys.remove(key)
        return true
    }

    func cancelAll() {
        for execution in active.values {
            cancellingKeys.insert(execution.key)
            execution.cancellation.cancel()
        }
    }

    func isCancelling(key: String) -> Bool { cancellingKeys.contains(key) }
}

/// Runs a saved script link's command in the background, debounced so typing
/// does not spawn a process per keystroke, and cached by exactly what was
/// typed so a later keystroke never overwrites the screen with a stale
/// answer meant for a different query.
///
/// Not part of the pure-function test harness (`./build.sh --test`): the
/// behavior here is a background process and a timer, not a calculation.
/// Verified by hand against a real saved script link instead.
final class CommandBarScriptRunner {
    struct Result: Equatable {
        let text: String
    }

    /// How long the query has to sit still before a script actually runs.
    static let debounce: TimeInterval = 0.25

    /// Called on the main thread whenever a result becomes ready, so the
    /// caller can refresh what is on screen.
    var onResult: (() -> Void)?

    private var cache: [String: Result] = [:]
    /// The keys whose process is running right now. Without it, a script
    /// slower than the debounce would be launched again by the next refresh
    /// while the first one is still going, since nothing is cached yet.
    /// Touched only from the main thread, like the cache, so it needs no lock.
    private var inFlight: Set<String> = []
    private let executions = CommandBarScriptExecutionRegistry()
    private var pendingWorkItem: DispatchWorkItem?
    private var generation = 0

    /// A result only belongs to the current opening of the bar. Clearing the
    /// session also prevents delayed work from a closed bar from publishing a
    /// stale answer when it opens again.
    func reset() {
        generation &+= 1
        cancelPending()
        cache.removeAll()
        inFlight.removeAll()
    }

    /// A query that no longer names a script must not leave its delayed run
    /// behind. Work already executing is bounded by Shell's timeout and its
    /// result is ignored unless this opening still owns it.
    func cancelPending() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
    }

    /// Feature removal is stronger than an ordinary close: terminate every
    /// saved query process, including work from a presentation already hidden.
    func cancelForFeatureDisable() {
        cancelPending()
        executions.cancelAll()
    }

    /// The answer for this exact link and argument, if the script already
    /// ran for it.
    func cachedResult(linkID: UUID, argument: String) -> Result? {
        cache[key(linkID, argument)]
    }

    /// Schedules a debounced run, replacing whatever was pending. Does
    /// nothing when a result is already cached for this exact link and
    /// argument, or when that same run is still going.
    func schedule(link: CommandBarLink, argument: String) {
        let cacheKey = key(link.id, argument)
        guard cachedResult(linkID: link.id, argument: argument) == nil,
              !inFlight.contains(cacheKey), !executions.isCancelling(key: cacheKey) else { return }
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.execute(link: link, argument: argument) }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: workItem)
    }

    /// Runs at once instead of waiting out the debounce, for the moment
    /// Return is pressed before a result exists yet.
    func runNow(link: CommandBarLink, argument: String) {
        let cacheKey = key(link.id, argument)
        guard cachedResult(linkID: link.id, argument: argument) == nil,
              !inFlight.contains(cacheKey), !executions.isCancelling(key: cacheKey) else { return }
        cancelPending()
        execute(link: link, argument: argument)
    }

    /// A run waits out its debounce or is going.
    var isAwaiting: Bool { pendingWorkItem != nil || !inFlight.isEmpty }

    private func execute(link: CommandBarLink, argument: String) {
        pendingWorkItem = nil
        let cacheKey = key(link.id, argument)
        let runGeneration = generation
        let path = (link.destination as NSString).expandingTildeInPath
        guard let execution = executions.begin(key: cacheKey) else { return }
        inFlight.insert(cacheKey)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (status, output) = Shell.run(path, [argument], maxOutputBytes: 64 * 1024,
                                             cancellation: execution.cancellation)
            let text = CommandBarLinks.resultText(output)
            // The hop back happens whatever the script printed: a run that
            // ends with nothing to show still has to stop counting as one in
            // flight, or that key would never be runnable again.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let finishedCancellation = self.executions.finish(execution, key: cacheKey)
                guard self.generation == runGeneration else {
                    if finishedCancellation { self.onResult?() }
                    return
                }
                self.inFlight.remove(cacheKey)
                guard let text = text ?? (status == 0 ? nil : self.failureText) else { return }
                self.cache[cacheKey] = Result(text: text)
                self.onResult?()
            }
        }
    }

    private var failureText: String {
        FeatureStrings.commandBar(L10n.shared.language).scriptRunFailed
    }

    private func key(_ linkID: UUID, _ argument: String) -> String {
        "\(linkID.uuidString)|\(argument)"
    }
}
