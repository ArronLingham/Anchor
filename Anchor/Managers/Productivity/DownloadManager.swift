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

import Combine
import Foundation
import SwiftUI
import Observation
import Defaults

@Observable
@MainActor
class DownloadManager {
    static let shared = DownloadManager()
    
    private(set) var isDownloading: Bool = false
    private(set) var isDownloadCompleted: Bool = false

    /// Icon of the file currently downloading, for `DownloadIconStyle`.
    ///
    /// This watcher only sees files appear in ~/Downloads — it never learns
    /// which app started the download — so the only icon available is the
    /// file's own. Resolved once when a download starts, never per frame:
    /// `NSWorkspace.icon(forFile:)` hits disk on every call.
    private(set) var activeFileIcon: NSImage?
    
    private let coordinator = AnchorViewCoordinator.shared
    /// Holds the Defaults subscription. Without somewhere to keep the
    /// AnyCancellable that `sink` returns, the subscription is torn down the
    /// instant it is created.
    private var cancellables = Set<AnyCancellable>()

    private let watchEpoch = DownloadWatchEpoch()
    private var watchTicket: UUID?
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.dynamicisland.downloads.monitor", qos: .utility)
    private var completionTimer: Timer?
    private var hasPerformedInitialScan: Bool = false
    private var initialCrDownloadFiles: Set<String> = []
    private var previousAllFiles: Set<String> = []
    private var ignoredFiles: Set<String> = []
    
    private var downloadsDirectory: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }
    
    init() {
        Defaults.publisher(.enableDownloadListener, options: [])
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self, watchEpoch] _ in
                watchEpoch.invalidate()
                DispatchQueue.main.async { self?.reconcileMonitor() }
            }
            .store(in: &cancellables)

        DispatchQueue.main.async { [weak self] in self?.reconcileMonitor() }
    }

    private func reconcileMonitor() {
        let ticket = watchEpoch.current()
        if watchTicket != nil && (watchTicket != ticket || !Defaults[.enableDownloadListener]) {
            stopMonitoring()
        }
        guard watchTicket == nil, Defaults[.enableDownloadListener], let directory = downloadsDirectory else { return }
        watchTicket = ticket

        queue.async { [weak self, watchEpoch] in
            guard watchEpoch.accepts(ticket) else { return }
            let fd = Self.openWatch(directory, ticket: ticket, epoch: watchEpoch)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.accepts(ticket) else {
                    if fd >= 0 { close(fd) }
                    return
                }
                guard fd >= 0 else {
                    self.watchTicket = nil
                    return
                }
                self.installMonitor(fd: fd, directory: directory, ticket: ticket)
            }
        }
    }

    nonisolated private static func openWatch(_ directory: URL, ticket: UUID, epoch: DownloadWatchEpoch) -> Int32 {
        let fd = open(directory.path, O_EVTONLY)
        guard fd < 0, epoch.accepts(ticket) else { return fd }
        // Preserve the explicit access attempt if the watcher cannot open the
        // directory until the user answers the Downloads permission prompt.
        guard (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) != nil,
              epoch.accepts(ticket) else { return -1 }
        return open(directory.path, O_EVTONLY)
    }

    private func accepts(_ ticket: UUID) -> Bool {
        watchTicket == ticket && Defaults[.enableDownloadListener] && watchEpoch.accepts(ticket)
    }

    private func installMonitor(fd: Int32, directory: URL, ticket: UUID) {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: queue
        )
        let scan: @Sendable () -> Void = { [weak self, watchEpoch] in
            guard watchEpoch.accepts(ticket),
                  let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            else { return }
            let downloads = Set(files.filter { name in
                let ext = (name as NSString).pathExtension.lowercased()
                return ext == "crdownload" || ext == "download"
            })
            let allFiles = Set(files)
            DispatchQueue.main.async { [weak self] in
                self?.processDownloadFiles(downloads, allFiles: allFiles, ticket: ticket)
            }
        }
        src.setEventHandler(handler: scan)
        src.setCancelHandler { close(fd) }

        source = src
        // Queue the initial baseline before the source can enqueue change events.
        queue.async(execute: scan)
        src.resume()
    }

    private func stopMonitoring() {
        watchTicket = nil
        source?.cancel()
        source = nil
        hasPerformedInitialScan = false
        initialCrDownloadFiles.removeAll()
        previousAllFiles.removeAll()
        ignoredFiles.removeAll()
        closeDownloadViewImmediately()
    }

    private func processDownloadFiles(_ crDownloadFiles: Set<String>, allFiles: Set<String>, ticket: UUID) {
        guard accepts(ticket) else { return }

        if !hasPerformedInitialScan {
            hasPerformedInitialScan = true
            initialCrDownloadFiles = crDownloadFiles
            previousAllFiles = allFiles
            ignoredFiles = crDownloadFiles
            isDownloading = false
            return
        }
        
        let newFiles = crDownloadFiles.subtracting(initialCrDownloadFiles)
        let disappearedFiles = initialCrDownloadFiles.subtracting(crDownloadFiles)
        let newRegularFiles = allFiles.subtracting(previousAllFiles).subtracting(crDownloadFiles)
        
        initialCrDownloadFiles = crDownloadFiles
        previousAllFiles = allFiles
        
        let activeFiles = crDownloadFiles.subtracting(ignoredFiles)
        let hasActiveDownloads = !activeFiles.isEmpty
        
        if !newFiles.isEmpty {
            let newActiveFiles = newFiles.subtracting(ignoredFiles)
            if !newActiveFiles.isEmpty {
                if !isDownloading || isDownloadCompleted {
                    updateDownloadingState(isActive: true, fileName: newActiveFiles.sorted().first)
                }
            }
        }
        
        // completion logic
        if isDownloading {
            if !hasActiveDownloads {
                if !newRegularFiles.isEmpty || disappearedFiles.isEmpty {
                    
                    if !isDownloadCompleted {
                        updateDownloadingState(isActive: false)
                    }
                    
                } else {
                    closeDownloadViewImmediately()
                }
                
            }
            
        } else if hasActiveDownloads {
            updateDownloadingState(isActive: true)
        }
    }
    
    /// The name of an in-flight download ends in .crdownload or .download;
    /// the icon we want is for the real extension underneath.
    private func resolveFileIcon(for inFlight: String?) -> NSImage? {
        guard let directory = downloadsDirectory, let inFlight else { return nil }

        var name = inFlight
        for suffix in [".crdownload", ".download"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        let icon = NSWorkspace.shared.icon(forFile: directory.appendingPathComponent(name).path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    private func updateDownloadingState(isActive: Bool, fileName: String? = nil) {
        completionTimer?.invalidate()
        completionTimer = nil
        
        if isActive {
            let shouldPresent = !isDownloading || isDownloadCompleted
            isDownloadCompleted = false
            
            if shouldPresent {
                activeFileIcon = resolveFileIcon(for: fileName)
                withAnimation(.smooth) {
                    isDownloading = true
                    coordinator.expandingView = ExpandedItem(show: true, type: .download)
                }
            }
            
        } else {
            if isDownloading {
                withAnimation(.smooth) {
                    isDownloadCompleted = true
                }
                
                guard let ticket = watchTicket else { return }
                completionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] timer in
                    MainActor.assumeIsolated {
                        guard let self, self.completionTimer === timer,
                              self.accepts(ticket) else { return }
                        self.closeDownloadViewImmediately()
                    }
                }
            }
        }
    }
    
    private func closeDownloadViewImmediately() {
        completionTimer?.invalidate()
        completionTimer = nil
        activeFileIcon = nil

        withAnimation(.smooth) {
            isDownloading = false
            isDownloadCompleted = false
            if coordinator.expandingView.show && coordinator.expandingView.type == .download {
                coordinator.expandingView.show = false
            }
        }
    }
}

/// Preference callbacks retire a watch before the main queue reconciles the
/// source. A worker may finish an existing OS read after its ticket expires.
private final class DownloadWatchEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var ticket = UUID()

    func current() -> UUID { lock.withLock { ticket } }
    func invalidate() { lock.withLock { ticket = UUID() } }
    func accepts(_ candidate: UUID) -> Bool { lock.withLock { ticket == candidate } }
}
