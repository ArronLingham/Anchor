// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CryptoKit
import Darwin
import Foundation

/// Experimental organizer for confirmed WhatsApp downloads. It watches only
/// the top level of Downloads, waits until a file is stable, then moves it to
/// the configured folder. File bytes are read only to calculate a local SHA-256
/// digest used for exact duplicate detection.
final class WhatsAppDownloadOrganizer: ObservableObject {
    static let shared = WhatsAppDownloadOrganizer()

    enum Phase: Equatable {
        case idle, waiting, organizing, undoing
        case done(moved: Int, duplicates: Int, failed: Int)
        case failed

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }
    }

    struct Record: Codable, Equatable {
        let digest: String
        let destinationPath: String
        let originalName: String
        let size: Int64
        let organizedAt: Date
    }

    struct UndoTransaction: Codable {
        enum ActionKind: String, Codable { case move, trash }
        struct Action: Codable, Equatable {
            let kind: ActionKind
            let currentPath: String
            let restorePath: String?
        }

        let id: UUID
        var actions: [Action]
        let recordsBefore: [Record]
        let recordsAfter: [Record]
        let createdAt: Date
        var partial: Bool? = nil
    }

    private struct SourceFile {
        let url: URL
        let fingerprint: String
        let size: Int64
        let downloadedAt: Date
        let modifiedAt: Date
        let category: WhatsAppDownloadCategory
    }

    private struct Settings {
        let destination: URL
        let delayMinutes: Int
        let categories: Set<WhatsAppDownloadCategory>
        let layout: WhatsAppOrganizerLayout
        let duplicateAction: WhatsAppDuplicateAction
    }

    private struct RunResult {
        let moved: Int
        let duplicates: Int
        let failed: Int
        let records: [Record]
        let undo: UndoTransaction?
        let nextEligible: Date?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var nextCheck: Date?
    @Published private(set) var hasPendingPartialUndo: Bool

    var isBusy: Bool { phase == .organizing || phase == .undoing }
    var canUndo: Bool {
        Self.validUndoTransactions().last != nil
    }
    var pendingPartialUndoID: UUID? {
        Self.validUndoTransactions().first(where: { $0.partial == true })?.id
    }

    private let queue = DispatchQueue(label: "com.vorssaint.whatsapp-organizer",
                                      qos: .utility)
    private var directorySource: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var operationToken = UUID()

    init() {
        hasPendingPartialUndo = Self.validUndoTransactions().contains { $0.partial == true }
    }

    static func destinationURL(defaults: UserDefaults = UtilityPreferences.standard,
                               downloadsURL: URL? = nil) -> URL? {
        let root = downloadsURL
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let root else { return nil }
        let configured = defaults.string(forKey: DefaultsKey.whatsAppOrganizerDestinationPath) ?? ""
        let destination = configured.isEmpty
            ? root.appendingPathComponent("WhatsApp", isDirectory: true)
            : URL(fileURLWithPath: configured, isDirectory: true)
        let standardized = destination.standardizedFileURL
        guard standardized.path != root.standardizedFileURL.path else {
            return root.appendingPathComponent("WhatsApp", isDirectory: true)
        }
        return standardized
    }

    static func managedDestinationPaths() -> Set<String> {
        Set(loadRecords().map { URL(fileURLWithPath: $0.destinationPath).standardizedFileURL.path })
    }

    func syncWithPreferences() {
        UtilityWorkspace.shared.prepareOwnership()
        stopMonitoring()
        guard AppFeature.cleaner.isAvailable,
              WhatsAppDownloadSupport.isEnabled,
              UtilityPreferences.standard.bool(forKey: DefaultsKey.whatsAppOrganizerEnabled),
              UtilityPreferences.standard.bool(forKey: DefaultsKey.whatsAppDownloadsAccessConfirmed),
              let root = downloadsURL else {
            if !isBusy { phase = .idle }
            return
        }
        guard !hasPendingPartialUndo else {
            if !isBusy { phase = .failed }
            return
        }
        startMonitoring(root: root)
        schedule(after: 2)
    }

    func stop() {
        stopMonitoring()
        // A file operation cannot be cancelled safely after it starts. Keep
        // its token and busy state until its result and undo data are saved.
        guard !isBusy else { return }
        operationToken = UUID()
        phase = .idle
    }

    /// The worker owns a transaction until its main-thread completion records
    /// the outcome, even if monitoring was stopped in the meantime.
    @discardableResult
    func performMutation<Result>(phase: Phase, work: @escaping () -> Result,
                                 finish: @escaping (Result) -> Void) -> Bool {
        guard !isBusy, phase == .organizing || phase == .undoing else { return false }
        let token = UUID()
        operationToken = token
        self.phase = phase
        queue.async { [weak self] in
            let result = work()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.operationToken == token else { return }
                finish(result)
                if self.operationToken == token, self.isBusy { self.phase = .idle }
            }
        }
        return true
    }

    @discardableResult
    func setDestination(_ url: URL?) -> Bool {
        guard let root = downloadsURL else { return false }
        if let url {
            let destination = url.standardizedFileURL
            guard destination.path != root.standardizedFileURL.path else { return false }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            UtilityPreferences.standard.set(destination.path,
                                      forKey: DefaultsKey.whatsAppOrganizerDestinationPath)
        } else {
            UtilityPreferences.standard.set("", forKey: DefaultsKey.whatsAppOrganizerDestinationPath)
        }
        syncWithPreferences()
        return true
    }

    func runNow() {
        run(manual: true)
    }

    func undoLastRun(transactionID: UUID? = nil) {
        guard AppFeature.cleaner.isAvailable, WhatsAppDownloadSupport.isEnabled, !isBusy else { return }
        let manager = WhatsAppDownloadManager.shared
        guard manager.phase != .scanning, manager.phase != .cleaning else { return }
        let transactions = Self.validUndoTransactions()
        let pending = transactions.first { $0.partial == true }
        if let pending, let transactionID, pending.id != transactionID { return }
        let transaction = pending ?? (transactionID.flatMap { id in
            transactions.first { $0.id == id }
        } ?? (transactionID == nil ? transactions.last : nil))
        guard let transaction,
              Self.recordsAllowUndo(transaction, current: Self.loadRecords()) else { return }
        performMutation(phase: .undoing, work: { Self.performUndo(transaction) }) { [weak self] progress in
            guard let self else { return }
            switch Self.commitUndoProgress(transaction, transactions: transactions, progress: progress) {
            case .complete:
                self.hasPendingPartialUndo = transactions.contains { $0.id != transaction.id && $0.partial == true }
                self.phase = .done(moved: 0, duplicates: 0, failed: 0)
                self.syncWithPreferences()
                WhatsAppDownloadScheduler.shared.syncWithPreferences()
            case .partial:
                self.hasPendingPartialUndo = true
                self.stopMonitoring()
                WhatsAppDownloadScheduler.shared.syncWithPreferences()
                self.phase = .failed
            case .failed:
                self.phase = .failed
            }
            if AppFeature.cleaner.isAvailable && WhatsAppDownloadSupport.isEnabled {
                WhatsAppDownloadManager.shared.scan()
            }
            self.schedule(after: 2)
        }
    }

    /// Discards only the unfinished undo record after explicit user consent.
    /// Files and managed-file records stay as they are.
    func discardPendingPartialUndo(id: UUID) {
        guard !isBusy else { return }
        guard pendingPartialUndoID == id, Self.discardPartialUndoTransaction(id: id) else { return }
        hasPendingPartialUndo = Self.validUndoTransactions().contains { $0.partial == true }
        phase = .idle
        syncWithPreferences()
        WhatsAppDownloadScheduler.shared.syncWithPreferences()
    }

    private var downloadsURL: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    private func startMonitoring(root: URL) {
        let descriptor = open(root.path, O_EVTONLY)
        guard descriptor >= 0 else {
            schedule(after: 300)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main)
        source.setEventHandler { [weak self] in self?.schedule(after: 2) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directorySource = source
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        nextCheck = nil
        directorySource?.cancel()
        directorySource = nil
    }

    private func schedule(after delay: TimeInterval) {
        guard AppFeature.cleaner.isAvailable, WhatsAppDownloadSupport.isEnabled,
              UtilityPreferences.standard.bool(forKey: DefaultsKey.whatsAppOrganizerEnabled),
              UtilityPreferences.standard.bool(forKey: DefaultsKey.whatsAppDownloadsAccessConfirmed),
              !hasPendingPartialUndo else { return }
        let date = Date().addingTimeInterval(max(1, delay))
        if let nextCheck, nextCheck <= date { return }
        timer?.invalidate()
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            self?.run(manual: false)
        }
        timer.tolerance = min(10, max(1, delay / 10))
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        nextCheck = date
        // A fresh .done stays visible as the green just-finished feedback;
        // everything else folds into the quiet waiting state.
        if !isBusy, !phase.isDone { phase = .waiting }
    }

    private func schedule(at date: Date?) {
        guard AppFeature.cleaner.isAvailable, WhatsAppDownloadSupport.isEnabled,
              UtilityPreferences.standard.bool(forKey: DefaultsKey.whatsAppOrganizerEnabled),
              UtilityPreferences.standard.bool(forKey: DefaultsKey.whatsAppDownloadsAccessConfirmed),
              !hasPendingPartialUndo else { return }
        guard let date else {
            nextCheck = nil
            phase = .waiting
            return
        }
        schedule(after: max(1, date.timeIntervalSinceNow))
    }

    private func run(manual: Bool) {
        timer?.invalidate()
        timer = nil
        nextCheck = nil
        // A pass already executing keeps its phase untouched: writing .idle
        // here would unmask the busy guard and let a second pass race the
        // first, orphaning the first pass's records and undo transaction.
        guard !isBusy else {
            schedule(after: 60)
            return
        }
        guard !hasPendingPartialUndo else { phase = .failed; return }
        guard AppFeature.cleaner.isAvailable,
              WhatsAppDownloadSupport.isEnabled,
              UtilityPreferences.standard.bool(forKey: DefaultsKey.whatsAppOrganizerEnabled),
              UtilityPreferences.standard.bool(forKey: DefaultsKey.whatsAppDownloadsAccessConfirmed),
              let root = downloadsURL,
              let settings = settings(root: root) else {
            phase = .idle
            return
        }
        let manager = WhatsAppDownloadManager.shared
        let managerBusy = manager.phase == .scanning || manager.phase == .cleaning
        guard !managerBusy, manual || !manager.reviewVisible else {
            schedule(after: 300)
            return
        }

        performMutation(phase: .organizing, work: { Self.organize(root: root, settings: settings) }) { [weak self] result in
            guard let self else { return }
            Self.saveRecords(result.records)
            if let undo = result.undo {
                var transactions = Self.validUndoTransactions()
                transactions.append(undo)
                Self.saveUndoTransactions(Array(transactions.suffix(20)))
            }
            let defaults = UtilityPreferences.standard
            defaults.set(Date().timeIntervalSince1970,
                         forKey: DefaultsKey.whatsAppOrganizerLastRun)
            defaults.set(result.moved, forKey: DefaultsKey.whatsAppOrganizerLastMoved)
            defaults.set(result.duplicates,
                         forKey: DefaultsKey.whatsAppOrganizerLastDuplicates)
            defaults.set(result.failed, forKey: DefaultsKey.whatsAppOrganizerLastFailed)
            self.phase = .done(moved: result.moved,
                               duplicates: result.duplicates,
                               failed: result.failed)
            if AppFeature.cleaner.isAvailable, WhatsAppDownloadSupport.isEnabled,
               result.moved + result.duplicates > 0,
               defaults.bool(forKey: DefaultsKey.whatsAppDownloadsNotify) {
                let strings = WhatsAppOrganizerStrings.localized(L10n.shared.language)
                let body = String(format: strings.notificationFormat,
                                  result.moved, result.duplicates, result.failed)
                if let undo = result.undo {
                    Notifier.postWhatsAppOrganization(
                        title: strings.notificationTitle, body: body,
                        undoTitle: strings.undo, transactionID: undo.id)
                } else {
                    Notifier.post(title: strings.notificationTitle, body: body)
                }
            }
            if AppFeature.cleaner.isAvailable, WhatsAppDownloadSupport.isEnabled,
               manager.reviewVisible { manager.scan() }
            self.schedule(at: result.nextEligible)
        }
    }

    private func settings(root: URL) -> Settings? {
        guard let destination = Self.destinationURL(downloadsURL: root) else { return nil }
        let defaults = UtilityPreferences.standard
        return Settings(
            destination: destination,
            delayMinutes: WhatsAppDownloadSupport.sanitizedOrganizerDelayMinutes(
                defaults.integer(forKey: DefaultsKey.whatsAppOrganizerDelayMinutes)),
            categories: WhatsAppDownloadSupport.decodedCategories(
                defaults.string(forKey: DefaultsKey.whatsAppOrganizerCategories)),
            layout: WhatsAppOrganizerLayout(
                rawValue: defaults.string(forKey: DefaultsKey.whatsAppOrganizerLayout) ?? "") ?? .flat,
            duplicateAction: WhatsAppDuplicateAction(
                rawValue: defaults.string(
                    forKey: DefaultsKey.whatsAppOrganizerDuplicateAction) ?? "") ?? .trashNew)
    }

    private static func organize(root: URL, settings: Settings) -> RunResult {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: settings.destination,
                                   withIntermediateDirectories: true)
        } catch {
            return RunResult(moved: 0, duplicates: 0, failed: 1,
                             records: loadRecords(), undo: nil, nextEligible: nil)
        }

        let now = Date()
        let files: [SourceFile]
        do {
            files = try sourceFiles(in: root)
        } catch {
            return RunResult(moved: 0, duplicates: 0, failed: 1,
                             records: loadRecords(), undo: nil, nextEligible: nil)
        }

        let recordsBefore = loadRecords()
        var records = recordsBefore.filter {
            fm.fileExists(atPath: $0.destinationPath)
        }
        var undoActions: [UndoTransaction.Action] = []
        var moved = 0
        var duplicates = 0
        var failed = 0
        var nextEligible: Date?

        for source in files where settings.categories.contains(source.category) {
            guard WhatsAppDownloadSupport.isStableForOrganization(
                downloadedAt: source.downloadedAt, modifiedAt: source.modifiedAt,
                now: now, delayMinutes: settings.delayMinutes) else {
                let base = max(source.downloadedAt, source.modifiedAt)
                let eligible = base.addingTimeInterval(
                    TimeInterval(settings.delayMinutes * 60 + 1))
                nextEligible = min(nextEligible ?? eligible, eligible)
                continue
            }

            do {
                guard fingerprint(for: source.url) == source.fingerprint else {
                    failed += 1
                    continue
                }
                let digest = try sha256(of: source.url)
                let validDuplicateIndex = try firstValidRecordIndex(
                    digest: digest, records: &records)
                guard sourceStillMatches(source) else {
                    failed += 1
                    continue
                }

                if let duplicateIndex = validDuplicateIndex {
                    let existing = URL(fileURLWithPath: records[duplicateIndex].destinationPath)
                    switch settings.duplicateAction {
                    case .trashNew:
                        let trashed = try trash(source.url)
                        if let trashed {
                            undoActions.insert(.init(kind: .move,
                                                     currentPath: trashed.path,
                                                     restorePath: source.url.path), at: 0)
                        }
                        duplicates += 1
                        continue
                    case .replaceExisting:
                        let actions = try replaceVerified(source: source.url,
                                                          existing: existing,
                                                          digest: digest)
                        records[duplicateIndex] = Record(
                            digest: digest, destinationPath: existing.path,
                            originalName: source.url.lastPathComponent,
                            size: source.size, organizedAt: now)
                        undoActions.insert(contentsOf: actions, at: 0)
                        moved += 1
                        duplicates += 1
                        continue
                    case .keepBoth:
                        break
                    }
                }

                let components = WhatsAppDownloadSupport.organizerRelativeComponents(
                    layout: settings.layout, category: source.category,
                    date: source.downloadedAt)
                let folder = components.reduce(settings.destination) {
                    $0.appendingPathComponent($1, isDirectory: true)
                }
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = uniqueDestination(
                    in: folder, preferredName: source.url.lastPathComponent)
                let actions = try moveVerified(source: source.url,
                                               destination: destination,
                                               digest: digest)
                undoActions.insert(contentsOf: actions, at: 0)
                records.append(Record(digest: digest,
                                      destinationPath: destination.path,
                                      originalName: source.url.lastPathComponent,
                                      size: source.size, organizedAt: now))
                moved += 1
            } catch {
                failed += 1
            }
        }

        records = Array(records.sorted { $0.organizedAt < $1.organizedAt }.suffix(5_000))
        let undo = undoActions.isEmpty ? nil : UndoTransaction(
            id: UUID(), actions: undoActions, recordsBefore: recordsBefore,
            recordsAfter: records, createdAt: now)
        return RunResult(moved: moved, duplicates: duplicates, failed: failed,
                         records: records, undo: undo, nextEligible: nextEligible)
    }

    private static let sourceResourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .isDirectoryKey,
        .isPackageKey, .isHiddenKey, .fileSizeKey, .contentTypeKey,
        .quarantinePropertiesKey, .addedToDirectoryDateKey, .creationDateKey,
        .contentModificationDateKey,
    ]

    private static func sourceFiles(in root: URL) throws -> [SourceFile] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(sourceResourceKeys),
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard WhatsAppDownloadSupport.isDirectChild(standardized, of: root),
                  !WhatsAppDownloadSupport.isIncompleteFile(
                    extension: standardized.pathExtension),
                  let values = try? standardized.resourceValues(forKeys: sourceResourceKeys),
                  values.isRegularFile == true,
                  values.isDirectory != true,
                  values.isPackage != true,
                  values.isSymbolicLink != true,
                  values.isAliasFile != true,
                  values.isHidden != true,
                  let quarantine = values.quarantineProperties,
                  WhatsAppDownloadSupport.isWhatsAppAgent(
                    quarantine["LSQuarantineAgentName"] as? String),
                  let downloadedAt = (quarantine["LSQuarantineTimeStamp"] as? Date)
                    ?? values.addedToDirectoryDate ?? values.creationDate,
                  let fingerprint = fingerprint(for: standardized)
            else { return nil }
            let modified = values.contentModificationDate ?? downloadedAt
            let category = WhatsAppDownloadSupport.category(
                contentTypeIdentifier: values.contentType?.identifier,
                extension: standardized.pathExtension)
            return SourceFile(url: standardized, fingerprint: fingerprint,
                              size: Int64(values.fileSize ?? 0),
                              downloadedAt: downloadedAt, modifiedAt: modified,
                              category: category)
        }
    }

    private static func firstValidRecordIndex(digest: String,
                                              records: inout [Record]) throws -> Int? {
        var index = 0
        while index < records.count {
            guard records[index].digest == digest else {
                index += 1
                continue
            }
            let url = URL(fileURLWithPath: records[index].destinationPath)
            guard FileManager.default.fileExists(atPath: url.path),
                  (try? sha256(of: url)) == digest else {
                records.remove(at: index)
                continue
            }
            return index
        }
        return nil
    }

    private static func uniqueDestination(in folder: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        let preferred = folder.appendingPathComponent(preferredName)
        guard fm.fileExists(atPath: preferred.path) else { return preferred }
        let source = URL(fileURLWithPath: preferredName)
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private static func moveVerified(source: URL,
                                     destination: URL,
                                     digest: String) throws -> [UndoTransaction.Action] {
        let fm = FileManager.default
        let sourceVolume = (try? source.resourceValues(forKeys: [.volumeIdentifierKey]))?
            .volumeIdentifier as? NSObject
        let destinationVolume = (try? destination.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject

        if WhatsAppDownloadSupport.isSameVolume(source: sourceVolume,
                                                destination: destinationVolume) {
            // Same volume: this is a rename, so no byte ever moves and the
            // digest cannot change. Re-hashing here read a second full copy of
            // every file - on a multi-gigabyte video, longer than the move.
            // The cross-volume branch below copies and must still verify.
            try fm.moveItem(at: source, to: destination)
            return [.init(kind: .move, currentPath: destination.path,
                          restorePath: source.path)]
        }

        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".vorssaint-\(UUID().uuidString).partial")
        do {
            try fm.copyItem(at: source, to: temporary)
            guard try sha256(of: temporary) == digest else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try fm.moveItem(at: temporary, to: destination)
            guard let trashedSource = try trash(source) else {
                _ = try? trash(destination)
                throw CocoaError(.fileWriteUnknown)
            }
            return [
                .init(kind: .trash, currentPath: destination.path, restorePath: nil),
                .init(kind: .move, currentPath: trashedSource.path, restorePath: source.path),
            ]
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    private static func replaceVerified(source: URL,
                                        existing: URL,
                                        digest: String) throws -> [UndoTransaction.Action] {
        let fm = FileManager.default
        let staging = existing.deletingLastPathComponent().appendingPathComponent(
            ".vorssaint-replaced-\(UUID().uuidString).partial")
        try fm.moveItem(at: existing, to: staging)
        do {
            let newActions = try moveVerified(source: source,
                                              destination: existing,
                                              digest: digest)
            guard let trashedExisting = try trash(staging) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return newActions + [
                .init(kind: .move, currentPath: trashedExisting.path,
                      restorePath: existing.path),
            ]
        } catch {
            if !fm.fileExists(atPath: existing.path) {
                try? fm.moveItem(at: staging, to: existing)
            } else {
                _ = try? trash(staging)
            }
            throw error
        }
    }

    private static func trash(_ url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprint(for url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        return "\(device):\(inode)"
    }

    private static func sourceStillMatches(_ source: SourceFile) -> Bool {
        guard fingerprint(for: source.url) == source.fingerprint,
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: source.url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else { return false }
        return size == source.size
            && abs(modified.timeIntervalSince(source.modifiedAt)) < 0.001
    }

    static func loadRecords(defaults: UserDefaults = UtilityPreferences.standard) -> [Record] {
        guard let data = defaults.data(forKey: DefaultsKey.whatsAppOrganizerRecords),
              !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    static func saveRecords(_ records: [Record], defaults: UserDefaults = UtilityPreferences.standard) {
        let data = (try? JSONEncoder().encode(records)) ?? Data()
        defaults.set(data, forKey: DefaultsKey.whatsAppOrganizerRecords)
    }

    static func loadUndoTransactions(defaults: UserDefaults = UtilityPreferences.standard) -> [UndoTransaction] {
        guard let data = defaults.data(
            forKey: DefaultsKey.whatsAppOrganizerUndoTransaction),
              !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([UndoTransaction].self, from: data)) ?? []
    }

    static func validUndoTransactions(_ transactions: [UndoTransaction], now: Date = Date()) -> [UndoTransaction] {
        transactions
            .filter { $0.partial == true || WhatsAppDownloadSupport.organizerUndoIsValid(
                createdAt: $0.createdAt, now: now) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private static func validUndoTransactions(now: Date = Date()) -> [UndoTransaction] {
        validUndoTransactions(loadUndoTransactions(), now: now)
    }

    static func saveUndoTransactions(_ transactions: [UndoTransaction],
                                     defaults: UserDefaults = UtilityPreferences.standard) {
        let data = (try? JSONEncoder().encode(transactions)) ?? Data()
        defaults.set(data, forKey: DefaultsKey.whatsAppOrganizerUndoTransaction)
    }

    private static func recordMap(_ records: [Record]) -> [String: Record] {
        Dictionary(records.map { ($0.destinationPath, $0) },
                   uniquingKeysWith: { _, latest in latest })
    }

    private static func affectedRecordPaths(_ transaction: UndoTransaction) -> Set<String> {
        let before = recordMap(transaction.recordsBefore)
        let after = recordMap(transaction.recordsAfter)
        return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
    }

    @discardableResult
    static func discardPartialUndoTransaction(id: UUID,
                                              defaults: UserDefaults = UtilityPreferences.standard) -> Bool {
        let transactions = loadUndoTransactions(defaults: defaults)
        guard validUndoTransactions(transactions).first(where: { $0.partial == true })?.id == id else { return false }
        saveUndoTransactions(transactions.filter { !($0.id == id && $0.partial == true) }, defaults: defaults)
        return true
    }

    static func recordsAllowUndo(_ transaction: UndoTransaction,
                                 current: [Record]) -> Bool {
        let expected = recordMap(transaction.recordsAfter)
        let current = recordMap(current)
        return affectedRecordPaths(transaction).allSatisfy { current[$0] == expected[$0] }
    }

    private static func recordsAfterUndo(_ transaction: UndoTransaction,
                                         current: [Record]) -> [Record] {
        let before = recordMap(transaction.recordsBefore)
        var result = recordMap(current)
        for path in affectedRecordPaths(transaction) {
            result[path] = before[path]
        }
        return result.values.sorted { $0.organizedAt < $1.organizedAt }
    }

    struct UndoProgress {
        let completed: Int
        let remaining: [UndoTransaction.Action]
    }

    enum UndoCommitOutcome: Equatable { case complete, partial, failed }

    static func commitUndoProgress(_ transaction: UndoTransaction,
                                   transactions: [UndoTransaction], progress: UndoProgress,
                                   defaults: UserDefaults = UtilityPreferences.standard) -> UndoCommitOutcome {
        if progress.remaining.isEmpty {
            saveRecords(recordsAfterUndo(transaction, current: loadRecords(defaults: defaults)), defaults: defaults)
            saveUndoTransactions(transactions.filter { $0.id != transaction.id }, defaults: defaults)
            return .complete
        }
        guard progress.completed > 0 || transaction.partial == true else { return .failed }
        var partial = transaction
        partial.actions = progress.remaining
        partial.partial = true
        saveUndoTransactions(transactions.map { $0.id == partial.id ? partial : $0 }, defaults: defaults)
        return .partial
    }

    static func performUndo(_ transaction: UndoTransaction,
                            moveToTrash: (URL) throws -> Void = { _ = try trash($0) }) -> UndoProgress {
        let fm = FileManager.default
        for (index, action) in transaction.actions.enumerated() {
            let current = URL(fileURLWithPath: action.currentPath)
            guard fm.fileExists(atPath: current.path) else {
                return UndoProgress(completed: index, remaining: Array(transaction.actions[index...]))
            }
            do {
                switch action.kind {
                case .move:
                    guard let restorePath = action.restorePath else {
                        return UndoProgress(completed: index, remaining: Array(transaction.actions[index...]))
                    }
                    let restore = URL(fileURLWithPath: restorePath)
                    guard !fm.fileExists(atPath: restore.path) else {
                        return UndoProgress(completed: index, remaining: Array(transaction.actions[index...]))
                    }
                    try fm.createDirectory(at: restore.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fm.moveItem(at: current, to: restore)
                case .trash:
                    try moveToTrash(current)
                }
            } catch {
                return UndoProgress(completed: index, remaining: Array(transaction.actions[index...]))
            }
        }
        return UndoProgress(completed: transaction.actions.count, remaining: [])
    }
}
