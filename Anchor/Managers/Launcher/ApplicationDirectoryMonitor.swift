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
import Dispatch
import Darwin

/// Watches key application directories and notifies when their contents change.
final class ApplicationDirectoryMonitor {
    private struct Observation {
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
    }

    private final class State {
        var observations: [Observation] = []
        var pendingWorkItem: DispatchWorkItem?
        var stopped = false
    }

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let debounceInterval: TimeInterval
    private let changeHandler: @Sendable () -> Void
    private let state = State()

    init(
        directories: [URL],
        debounceInterval: TimeInterval = 1.25,
        queue: DispatchQueue = DispatchQueue(label: "anchor.app-directory-monitor", qos: .utility),
        changeHandler: @escaping @Sendable () -> Void
    ) {
        self.queue = queue
        self.debounceInterval = debounceInterval
        self.changeHandler = changeHandler
        queue.setSpecific(key: queueKey, value: true)
        observe(directories: directories)
    }

    deinit {
        stop()
    }

    /// Cancels all observations and stops scheduling refresh callbacks.
    func stop() {
        let state = self.state
        let cancel = {
            state.stopped = true
            state.pendingWorkItem?.cancel()
            state.pendingWorkItem = nil
            for observation in state.observations { observation.source.cancel() }
            state.observations.removeAll()
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { cancel() }
        else { queue.sync(execute: cancel) }
    }

    /// Registers file system watchers for the provided application directories.
    private func observe(directories: [URL]) {
        let directoriesToWatch = uniqueDirectories(from: directories)
        for directory in directoriesToWatch {
            guard FileManager.default.fileExists(atPath: directory.path) else {
                continue
            }
            guard let descriptor = openDirectoryDescriptor(at: directory.path) else {
                continue
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [
                    .write,
                    .delete,
                    .extend,
                    .attrib,
                    .rename,
                    .link
                ],
                queue: queue
            )

            source.setEventHandler { [weak self] in
                self?.scheduleChange()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            state.observations.append(Observation(descriptor: descriptor, source: source))
        }
    }

    /// Deduplicates directory paths so we do not double-register observers.
    private func uniqueDirectories(from directories: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        for directory in directories {
            let standardized = directory.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            unique.append(standardized)
        }
        return unique
    }

    /// Opens a directory descriptor suitable for monitoring file system events.
    private func openDirectoryDescriptor(at path: String) -> Int32? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        return descriptor
    }

    /// Debounces rapid file system signals before invoking the caller's handler.
    private func scheduleChange() {
        guard !state.stopped else { return }
        state.pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.state.stopped else { return }
            self.changeHandler()
        }
        state.pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
