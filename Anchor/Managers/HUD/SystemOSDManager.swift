/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import AppKit
import os


class SystemOSDManager {
    private init() {}

    // Tracks the PID we most recently suspended. macOS jetsam-exits OSDUIHelper
    // when idle and launchd respawns it on the next media-key press as a fresh
    // process, so we need to re-SIGSTOP every new incarnation.
    private struct SuppressionState {
        var task: Task<Void, Never>?
        var lastSuspendedPID: Int32 = -1
        // True while suppressing the native OSD (between disable/enableSystemHUD).
        var active = false
        // True while the Mac is asleep — watcher pauses, not cancelled.
        var systemSleeping = false
        // Invalidates asynchronous enable/disable work left over from an older
        // settings state. HUD style switches update several Defaults in quick
        // succession, so those transitions must not race each other.
        var transitionGeneration: UInt64 = 0
        // Coalesces immediate suppression requests from a key event and its
        // resulting system-value notification.
        var immediateSuppressionInFlight = false
    }
    private static let suppressionState = OSAllocatedUnfairLock(initialState: SuppressionState())

    /// Serialises process-exit sources and their timeouts.
    private static let watcherQueue = DispatchQueue(
        label: "com.anchor.osd-suppression-watcher", qos: .utility)

    /// Call once at startup to register sleep/wake observers.
    /// Safe to call multiple times — observers are registered only once.
    private static let sleepWakeSetupOnce: Void = {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            handleSystemSleep()
        }
        nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            handleSystemWake()
        }
    }()

    // MARK: - Sleep / Wake

    private static func handleSystemSleep() {
        // Mark as sleeping so the watcher loop exits its current poll immediately.
        suppressionState.withLock { $0.systemSleeping = true }
        // Stop the watcher task — no more pgrep spawns while sleeping.
        stopSuppressionWatcher()
    }

    private static func handleSystemWake() {
        suppressionState.withLock { $0.systemSleeping = false }
        // If suppression was still active when we went to sleep, restart the watcher.
        let active = suppressionState.withLock { $0.active }
        if active {
            // Reset the last-suspended PID so the watcher immediately re-suspends
            // the fresh OSDUIHelper that launchd may have spawned during wake.
            suppressionState.withLock { $0.lastSuspendedPID = -1 }
            startSuppressionWatcher()
        }
    }

    // MARK: - Public API

    /// Release suppression and let the system service continue on its own.
    public static func enableSystemHUD() {
        suppressionState.withLock { state in
            state.active = false
            state.transitionGeneration &+= 1
            state.lastSuspendedPID = -1
            signalOSDUIHelper(SIGCONT)
        }
        stopSuppressionWatcher()
    }

    public static func resumeOSDUIHelperForTermination() {
        enableSystemHUD()
    }

    public static func disableSystemHUD() {
        _ = sleepWakeSetupOnce
        suppressionState.withLock { state in
            state.active = true
            state.transitionGeneration &+= 1
        }
        startSuppressionWatcher()
    }

    public static func suppressNativeOSDNow() {
        let generation = suppressionState.withLock { state -> UInt64? in
            guard state.active, !state.systemSleeping, !state.immediateSuppressionInFlight else { return nil }
            state.immediateSuppressionInFlight = true
            return state.transitionGeneration
        }
        guard let generation else { return }

        Task.detached(priority: .userInitiated) {
            if let pid = osduiHelperPID() { suspendIfCurrent(pid, generation: generation) }
            suppressionState.withLock { $0.immediateSuppressionInFlight = false }
        }
    }

    private static func suspendIfCurrent(_ pid: pid_t, generation: UInt64) {
        // Hold the same lock through the signal and through SIGCONT on release.
        // A late watcher or key callback cannot stop the helper after release.
        suppressionState.withLock { state in
            guard state.active, !state.systemSleeping, state.transitionGeneration == generation,
                  state.lastSuspendedPID != pid, isSystemHelper(pid) else { return }
            if kill(pid, SIGSTOP) == 0 { state.lastSuspendedPID = pid }
        }
    }

    private static func startSuppressionWatcher() {
        let generation = suppressionState.withLock { $0.transitionGeneration }
        let newTask = Task.detached(priority: .background) {
            while !Task.isCancelled {
                let wantsSuppression = suppressionState.withLock {
                    $0.active && !$0.systemSleeping && $0.transitionGeneration == generation
                }
                guard wantsSuppression else { return }
                if let pid = osduiHelperPID() {
                    suspendIfCurrent(pid, generation: generation)
                    await awaitExit(of: pid, timeoutSeconds: 60)
                } else {
                    let parked = SystemActivityGate.shared.shouldSuspendBackgroundWork
                    try? await Task.sleep(nanoseconds: parked ? 10_000_000_000 : 1_000_000_000)
                }
            }
        }

        let previous = suppressionState.withLock { state -> Task<Void, Never>? in
            guard state.active, !state.systemSleeping, state.transitionGeneration == generation else {
                newTask.cancel()
                return nil
            }
            let prior = state.task
            state.task = newTask
            return prior
        }
        previous?.cancel()
    }

    private static func stopSuppressionWatcher() {
        let previous = suppressionState.withLock { state -> Task<Void, Never>? in
            let prior = state.task
            state.task = nil
            return prior
        }
        previous?.cancel()
    }

    private static let osdHelperProcessName = "OSDUIHelper"

    private static func pids(named name: String) -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }

        var buffer = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let byteCount = Int32(buffer.count * MemoryLayout<pid_t>.size)
        let found = proc_listallpids(&buffer, byteCount)
        guard found > 0 else { return [] }

        var matches: [pid_t] = []
        var nameBuffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        for pid in buffer.prefix(Int(found)) where pid > 0 {
            guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { continue }
            if String(cString: nameBuffer) == name, isSystemHelper(pid) { matches.append(pid) }
        }
        return matches.sorted()
    }

    private static func isSystemHelper(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path) == "/System/Library/CoreServices/OSDUIHelper.app/Contents/MacOS/OSDUIHelper"
    }

    private static func osduiHelperPID() -> pid_t? {
        pids(named: osdHelperProcessName).last
    }

    private static func signalOSDUIHelper(_ signal: Int32) {
        for pid in pids(named: osdHelperProcessName) where isSystemHelper(pid) {
            if kill(pid, signal) != 0 && errno != ESRCH {
                NSLog("SystemOSDManager: kill(\(pid), \(signal)) failed: \(String(cString: strerror(errno)))")
            }
        }
    }

    private static func isOSDUIHelperRunning() -> Bool {
        osduiHelperPID() != nil
    }

    /// Suspends the caller until `pid` exits, or `timeoutSeconds` elapses.
    ///
    /// Backed by a GCD process source, so a live (and SIGSTOP'd) helper costs
    /// nothing while we wait — this is what replaces the 150ms poll. The
    /// timeout is a safety net so a missed event cannot wedge the watcher.
    /// Resumes its continuation exactly once, from whichever of the process
    /// source, the timeout, or task cancellation gets there first.
    private final class ExitWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var source: DispatchSourceProcess?
        private var finished = false

        func arm(_ continuation: CheckedContinuation<Void, Never>, source: DispatchSourceProcess) {
            lock.lock()
            if finished {
                // Cancelled before we got here; hand the continuation straight back.
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            self.source = source
            lock.unlock()
        }

        func finish() {
            lock.lock()
            guard !finished else { return lock.unlock() }
            finished = true
            let pending = continuation
            let pendingSource = source
            continuation = nil
            source = nil
            lock.unlock()

            pendingSource?.cancel()
            pending?.resume()
        }
    }

    private static func awaitExit(of pid: pid_t, timeoutSeconds: Int) async {
        // Cancellation-aware on purpose: a plain withCheckedContinuation ignores
        // Task.cancel(), so the watcher would stay parked here until the timeout
        // and stall app termination while the quit handler waits on it.
        let waiter = ExitWaiter()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let source = DispatchSource.makeProcessSource(
                    identifier: pid, eventMask: .exit, queue: watcherQueue)
                source.setEventHandler { waiter.finish() }
                waiter.arm(continuation, source: source)
                source.resume()

                // The process may have exited before the source was armed, in
                // which case .exit never fires.
                if kill(pid, 0) != 0 && errno == ESRCH {
                    waiter.finish()
                    return
                }

                watcherQueue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                    waiter.finish()
                }
            }
        } onCancel: {
            waiter.finish()
        }
    }
    
    /// Async version of status checking to avoid main thread blocking
    public static func isOSDUIHelperRunningAsync() async -> Bool {
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .background) {
                let result = isOSDUIHelperRunning()
                continuation.resume(returning: result)
            }
        }
    }
}
