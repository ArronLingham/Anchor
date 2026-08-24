/*
 * Atoll (DynamicIsland)
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

import AppKit
import Combine
import Defaults
import Foundation
import SwiftUI

/// Ties the Claude usage-limit pieces together: watch transcripts, tell the
/// phone when the window reopens, count down in the notch, and optionally
/// resume the session that was cut off.
///
/// Everything here fails soft. A missing binary, an unreadable transcript, a
/// rejected push — all of them log and carry on. Nothing in this file is
/// allowed to take the notch down with it.
@MainActor
final class ClaudeUsageManager: ObservableObject {
    static let shared = ClaudeUsageManager()

    enum Phase: Equatable {
        case idle
        case limited
        case resuming
        case resumed
    }

    /// The ticking half, deliberately on its own observable.
    ///
    /// `remaining` changes once a second while the countdown is on screen.
    /// `ContentView` observes twelve `ObservableObject`s and has no per-property
    /// granularity, so publishing a per-second value from the manager itself
    /// would re-render the entire 2,100-line notch every second for hours.
    /// Only `ClaudeUsageLiveActivity` observes this object.
    @MainActor
    final class LiveState: ObservableObject {
        @Published fileprivate(set) var phase: Phase = .idle
        @Published fileprivate(set) var resetDate: Date?
        @Published fileprivate(set) var remaining: TimeInterval = 0
    }

    let live = LiveState()

    /// Whether the notch should be showing the Claude live activity at all.
    ///
    /// This is the *only* thing `ContentView` observes from this manager, and it
    /// flips a handful of times per usage window. The per-second countdown is on
    /// `live`; publishing it here would re-render the whole notch every second
    /// for hours, because `@ObservedObject` invalidates on the object rather
    /// than the property.
    @Published private(set) var isLiveActivityVisible = false

    // MARK: - Tuning

    /// How long the "resumed" state lingers in the notch before going quiet.
    private static let resumedLinger: TimeInterval = 60
    /// Notch alert duration is set in `toggleSneakPeek`; this is the sneak-peek
    /// call's nominal argument, which that switch overrides.
    private static let alertDuration: TimeInterval = 6
    /// Countdown tolerance. A second-resolution readout does not need a
    /// second-accurate wakeup, and slack lets macOS coalesce the timer.
    private static let tickTolerance: TimeInterval = 0.25
    /// Cap on the dedupe set so a long-lived app cannot grow it without bound.
    private static let seenKeyLimit = 200

    // MARK: - State

    /// A session that stopped because the window closed.
    private struct HaltedSession {
        let sessionId: String
        let cwd: String
        let observedAt: Date
        let resetDate: Date
        /// Transcript path and its size when the banner was seen.
        ///
        /// A session that genuinely stopped writes nothing after its banner. One
        /// that merely *mentioned* a limit — Claude quoting the format while
        /// working on this very feature — keeps appending. Comparing the size at
        /// reset is the only check that actually separates the two:
        /// `ClaudeSessionRegistry.isAlive` cannot, because it runs hours later
        /// by which point even a healthy session has long exited.
        let transcriptPath: String
        let transcriptSize: UInt64
    }

    /// Consecutive automatic resumes of the same session, and the id they belong
    /// to. A resumed run appends to the transcript the watcher is watching, so a
    /// task too large for one window rewrites the banner and re-arms the whole
    /// loop with a new reset instant — indefinitely, unattended.
    private var consecutiveResumes = 0
    private var consecutiveResumeSessionId: String?

    /// Give up rather than keep feeding an unattended loop.
    private static let maxConsecutiveResumes = 3

    /// A reset that lapsed while the Mac slept is still worth resuming, but only
    /// for so long — waking to find a job restarted from yesterday is worse than
    /// not restarting it.
    private static let maxResumeLateness: TimeInterval = 2 * 60 * 60

    private var halted: [HaltedSession] = []
    /// `sessionId` + reset instant, so the same banner re-read from a grown
    /// transcript tail does not re-notify.
    private var seenKeys: [String] = []
    private var seenKeySet: Set<String> = []

    private var watcher: ClaudeTranscriptWatcher?
    private var resetTimer: DispatchSourceTimer?
    private var tickTimer: DispatchSourceTimer?
    private var lingerTask: Task<Void, Never>?

    /// Guards the reset handler. A `DispatchSourceTimer` does not fire reliably
    /// across system sleep, so the wake notification also calls in — without
    /// this flag a sleep that ends just after the reset would fire both.
    private var hasHandledReset = true

    private var visibleCountdowns = 0
    private var isSuspended = false
    private var didStart = false
    private var cancellables = Set<AnyCancellable>()

    /// Does nothing on purpose.
    ///
    /// SwiftUI builds `AppDelegate`'s stored properties on the main thread
    /// before the run loop starts, and anything that blocks in a singleton's
    /// `init` — a TCC-gated directory read, an FSEvents stream — deadlocks the
    /// whole app at launch. All real work happens in `start()`.
    private init() {}

    // MARK: - Lifecycle

    /// Call from the app's launch path via `DispatchQueue.main.async`.
    func start() {
        guard !didStart else { return }
        didStart = true

        Defaults.publisher(.claudeUsageWatchEnabled)
            .sink { [weak self] change in
                Task { @MainActor in self?.applyWatchEnabled(change.newValue) }
            }
            .store(in: &cancellables)

        // Visibility is derived from this key, so without a subscription turning
        // it off mid-window left the countdown occupying the notch for hours —
        // the state is only recomputed on a phase change, and a usage window has
        // none until it reopens.
        Defaults.publisher(.claudeUsageNotifyOnMac)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.setPhase(self.live.phase)
                }
            }
            .store(in: &cancellables)

        SystemActivityGate.shared.$shouldSuspendBackgroundWork
            .removeDuplicates()
            .sink { [weak self] suspend in
                Task { @MainActor in
                    guard let self else { return }
                    self.isSuspended = suspend
                    self.updateTicker()
                }
            }
            .store(in: &cancellables)

        // A timer set for hours out does not survive a sleep reliably; the wake
        // notification is what actually catches a reset that passed while the
        // Mac was asleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }

        applyWatchEnabled(Defaults[.claudeUsageWatchEnabled])
    }

    private func applyWatchEnabled(_ enabled: Bool) {
        if enabled {
            startWatching()
        } else {
            stopWatching()
        }
    }

    /// Normally `~/.claude/projects`. `ANCHOR_CLAUDE_PROJECTS_ROOT` redirects it
    /// at a fixture tree so the whole detect → count down → resume path can be
    /// exercised without appending to a real transcript — which would mean
    /// writing into Claude Code's own state, something this feature never does.
    /// Inert unless the variable is set, like `ANCHOR_RENDER_UI`.
    static var projectsRoot: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ANCHOR_CLAUDE_PROJECTS_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "projects", directoryHint: .isDirectory)
    }

    private func startWatching() {
        guard watcher == nil else { return }

        let root = Self.projectsRoot

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            Logger.log(
                "Claude usage: \(root.path) does not exist; not watching",
                category: .warning)
            return
        }

        let watcher = ClaudeTranscriptWatcher(root: root) { [weak self] hit in
            // Arrives on the watcher's own background queue.
            Task { @MainActor in self?.handle(hit) }
        }
        watcher.start()
        self.watcher = watcher
        Logger.log("Claude usage: watching \(root.path)", category: .lifecycle)
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
        cancelResetTimer()
        stopTicker()
        halted.removeAll()
        live.resetDate = nil
        live.remaining = 0
        setPhase(.idle)
    }

    // MARK: - Hits

    private func handle(_ hit: ClaudeTranscriptWatcher.Hit) {
        guard Defaults[.claudeUsageWatchEnabled] else { return }

        let resetDate = hit.limit.resetDate

        // The watcher scans an existing tail the first time it sees a file, so
        // banners from windows that reopened days ago do arrive here.
        guard resetDate > Date() else { return }

        let key = "\(hit.sessionId)@\(Int(resetDate.timeIntervalSince1970))"
        guard !seenKeySet.contains(key) else { return }
        rememberKey(key)

        halted.append(HaltedSession(
            sessionId: hit.sessionId,
            cwd: hit.cwd,
            observedAt: hit.observedAt,
            resetDate: resetDate,
            transcriptPath: hit.transcriptPath,
            transcriptSize: Self.fileSize(hit.transcriptPath)))

        lingerTask?.cancel()
        lingerTask = nil

        // Several sessions can hit the same wall a few seconds apart with
        // slightly different reset instants; the last one to reopen is the one
        // worth counting down to.
        let target = max(resetDate, live.resetDate ?? .distantPast)
        live.resetDate = target
        live.remaining = max(0, target.timeIntervalSinceNow)
        setPhase(.limited)

        // Sent now, not at the reset: ntfy holds it and delivers at `target`
        // whatever the Mac is doing by then. A local timer would simply never
        // fire if the machine is asleep at that instant.
        //
        // The body stays generic — it crosses a public third-party server, so
        // no project names, prompts or transcript text. Session names go in the
        // Mac-side notch alert only.
        PhonePush.send(
            title: "Claude is back",
            body: "Your Claude usage window has reset.",
            deliverAt: target,
            completion: { ok in
                if !ok {
                    Logger.log("Claude usage: scheduled phone push not sent", category: .warning)
                }
            })

        showAlert(
            icon: "hourglass",
            title: String(localized: "Claude limit reached"),
            subtitle: Self.absoluteResetText(target, zone: hit.limit.timeZone),
            accent: .orange)

        scheduleReset(at: target)

        Logger.log(
            "Claude usage: limit for session \(hit.sessionId), resets \(target)",
            category: .lifecycle)
    }

    private func rememberKey(_ key: String) {
        seenKeySet.insert(key)
        seenKeys.append(key)
        while seenKeys.count > Self.seenKeyLimit {
            seenKeySet.remove(seenKeys.removeFirst())
        }
    }

    // MARK: - Reset scheduling

    private func scheduleReset(at date: Date) {
        cancelResetTimer()
        hasHandledReset = false

        let delay = max(0, date.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Seconds of slack on an hours-long wait; lets macOS coalesce the wake.
        timer.schedule(deadline: .now() + delay, leeway: .seconds(2))
        timer.setEventHandler {
            MainActor.assumeIsolated {
                ClaudeUsageManager.shared.handleReset()
            }
        }
        timer.resume()
        resetTimer = timer
    }

    private func cancelResetTimer() {
        resetTimer?.cancel()
        resetTimer = nil
    }

    private func handleWake() {
        guard !hasHandledReset, let resetDate = live.resetDate else { return }
        guard Date() >= resetDate else { return }
        Logger.log("Claude usage: reset passed during sleep; handling on wake", category: .lifecycle)
        handleReset()
    }

    private func handleReset() {
        guard !hasHandledReset else { return }
        hasHandledReset = true
        cancelResetTimer()

        live.remaining = 0
        setPhase(.resumed)

        let pending = halted.sorted { $0.observedAt > $1.observedAt }
        halted.removeAll()

        guard Defaults[.claudeUsageAutoResume], let target = pending.first else {
            showAlert(
                icon: "arrow.clockwise",
                title: String(localized: "Claude is back"),
                subtitle: String(localized: "Your usage window has reset."),
                accent: .green)
            scheduleLinger()
            return
        }

        setPhase(.resuming)
        let others = pending.dropFirst().map(\.sessionId)
        resume(target, others: Array(others))
    }

    private func scheduleLinger() {
        lingerTask?.cancel()
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.resumedLinger))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.live.phase == .resumed else { return }
            self.live.resetDate = nil
            self.live.remaining = 0
            self.setPhase(.idle)
        }
    }

    // MARK: - Resume

    /// Resumes exactly one session — the most recently halted one.
    ///
    /// Firing every queued session at the same instant would burn the fresh
    /// window down again within minutes, which is the failure this whole
    /// feature exists to avoid. The rest are named in the notch alert so the
    /// user can pick them up by hand.
    private func resume(_ session: HaltedSession, others: [String]) {
        let sessionId = session.sessionId
        let cwd = session.cwd

        // An empty field means "no instruction", not "send an empty prompt".
        // The placeholder in Settings says `continue`, so honour that.
        let configured = Defaults[.claudeUsageResumePrompt]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = configured.isEmpty ? "continue" : configured

        // Woken long after the fact: the user has moved on, and restarting
        // yesterday's job unasked is worse than leaving it.
        let lateness = Date().timeIntervalSince(session.resetDate)
        guard lateness <= Self.maxResumeLateness else {
            finishResume(sessionId: sessionId, others: others, outcome: .tooLate)
            return
        }

        // A resumed run appends to the same transcript, so a task too big for one
        // window re-arms this loop forever with nobody watching.
        if consecutiveResumeSessionId == sessionId,
           consecutiveResumes >= Self.maxConsecutiveResumes {
            finishResume(sessionId: sessionId, others: others, outcome: .loopGuard)
            return
        }

        let transcriptPath = session.transcriptPath
        let sizeAtBanner = session.transcriptSize

        DispatchQueue.global(qos: .utility).async {
            // Cheap, but it stats a directory — keep it off main.
            if ClaudeSessionRegistry.isAlive(sessionId: sessionId) {
                Task { @MainActor in
                    ClaudeUsageManager.shared.finishResume(
                        sessionId: sessionId,
                        others: others,
                        outcome: .alreadyRunning)
                }
                return
            }

            // The real test of "did this session actually stop". A session that
            // halted writes nothing after its banner; one that merely quoted the
            // wording — Claude discussing this feature — kept going. isAlive
            // cannot tell them apart, because by now neither is running.
            if !transcriptPath.isEmpty, Self.fileSize(transcriptPath) > sizeAtBanner {
                Task { @MainActor in
                    ClaudeUsageManager.shared.finishResume(
                        sessionId: sessionId,
                        others: others,
                        outcome: .keptWorking)
                }
                return
            }

            let outcome = Self.launchClaude(sessionId: sessionId, cwd: cwd, prompt: prompt)
            Task { @MainActor in
                ClaudeUsageManager.shared.finishResume(
                    sessionId: sessionId,
                    others: others,
                    outcome: outcome)
            }
        }
    }

    private enum ResumeOutcome {
        case launched
        case alreadyRunning
        /// The transcript grew after the banner, so the session never stopped —
        /// the banner was quoted text, not a real limit.
        case keptWorking
        /// Resumed too many windows in a row without finishing.
        case loopGuard
        /// The reset lapsed while the Mac slept, too long ago to act on.
        case tooLate
        case binaryMissing
        case failed(String)
    }

    private nonisolated static func fileSize(_ path: String) -> UInt64 {
        guard !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.uint64Value
    }

    /// Runs off the main thread. Detached: nothing waits for the process, and
    /// both output streams go to `/dev/null` — an undrained `Pipe` deadlocks a
    /// `Process` the moment the child fills the buffer.
    private nonisolated static func launchClaude(sessionId: String, cwd: String, prompt: String) -> ResumeOutcome {
        let process = Process()

        let arguments = ["-r", sessionId, "-p", prompt]
        if let binary = resolveClaudeBinary() {
            process.executableURL = binary
            process.arguments = arguments
        } else {
            // No hardcoded path: a PATH-only install (nvm, mise, asdf) still
            // resolves through env, and a genuinely missing binary reports as a
            // launch failure below rather than as a wrong guess.
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/env") else {
                return .binaryMissing
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["claude"] + arguments
        }

        var isDirectory: ObjCBool = false
        if !cwd.isEmpty,
           FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
           isDirectory.boolValue {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            return .launched
        } catch {
            let posix = error as NSError
            if posix.domain == NSCocoaErrorDomain, posix.code == NSFileNoSuchFileError {
                return .binaryMissing
            }
            return .failed(error.localizedDescription)
        }
    }

    /// Where `claude` is normally installed, in order. Deliberately a search
    /// rather than one hardcoded path — the npm installer, Homebrew and the
    /// standalone installer all put it somewhere different.
    private nonisolated static func resolveClaudeBinary() -> URL? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser

        // Lets a test point resume at a stub that records its argv, so the
        // launch path can be verified without spending a real usage window.
        // Debug-only: in a shipping build this would let anything that can set
        // the environment choose a binary Anchor then executes.
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ANCHOR_CLAUDE_BIN"],
           !override.isEmpty,
           manager.isExecutableFile(atPath: (override as NSString).expandingTildeInPath) {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        #endif

        let candidates = [
            home.appending(path: ".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]

        for path in candidates where manager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func finishResume(sessionId: String, others: [String], outcome: ResumeOutcome) {
        setPhase(.resumed)
        scheduleLinger()

        let short = Self.shortId(sessionId)
        let queued = others.isEmpty
            ? ""
            : " · \(others.count) more waiting"

        // Count consecutive resumes of the *same* session; any other outcome, or
        // a different session, means the loop is not running away.
        switch outcome {
        case .launched:
            if consecutiveResumeSessionId == sessionId {
                consecutiveResumes += 1
            } else {
                consecutiveResumeSessionId = sessionId
                consecutiveResumes = 1
            }
        default:
            consecutiveResumeSessionId = nil
            consecutiveResumes = 0
        }

        switch outcome {
        case .launched:
            Logger.log("Claude usage: resumed session \(sessionId)", category: .success)
            showAlert(
                icon: "arrow.clockwise",
                title: String(localized: "Claude resumed"),
                subtitle: "\(short)\(queued)",
                accent: .green)

        case .keptWorking:
            Logger.log(
                "Claude usage: \(sessionId) kept writing after the banner; treating it as a quoted limit, not a halt",
                category: .lifecycle)

        case .loopGuard:
            Logger.log(
                "Claude usage: \(sessionId) hit the consecutive-resume cap; not resuming again",
                category: .warning)
            showAlert(
                icon: "hand.raised",
                title: String(localized: "Claude is back"),
                subtitle: String(localized: "Stopped auto-resuming — pick it up by hand."),
                accent: .orange)

        case .tooLate:
            Logger.log(
                "Claude usage: reset for \(sessionId) lapsed too long ago to resume",
                category: .lifecycle)
            showAlert(
                icon: "clock.badge.xmark",
                title: String(localized: "Claude is back"),
                subtitle: String(localized: "Window reopened a while ago — not resuming."),
                accent: .orange)

        case .alreadyRunning:
            Logger.log("Claude usage: \(sessionId) already alive; nothing to resume", category: .lifecycle)
            showAlert(
                icon: "checkmark.circle",
                title: String(localized: "Claude is back"),
                subtitle: String(localized: "Session already running."),
                accent: .green)

        case .binaryMissing:
            Logger.log("Claude usage: could not find the claude binary", category: .error)
            showAlert(
                icon: "exclamationmark.triangle",
                title: String(localized: "Claude is back"),
                subtitle: String(localized: "Auto-resume failed — claude not found."),
                accent: .orange)
            PhonePush.send(
                title: "Claude is back",
                body: "The usage window reset, but auto-resume could not start Claude.",
                deliverAt: nil,
                completion: nil)

        case .failed(let message):
            Logger.log("Claude usage: resume failed: \(message)", category: .error)
            showAlert(
                icon: "exclamationmark.triangle",
                title: String(localized: "Claude is back"),
                subtitle: String(localized: "Auto-resume failed."),
                accent: .orange)
            PhonePush.send(
                title: "Claude is back",
                body: "The usage window reset, but auto-resume failed.",
                deliverAt: nil,
                completion: nil)
        }
    }

    // MARK: - Countdown ticker

    /// Called by `ClaudeUsageLiveActivity` as it comes and goes.
    ///
    /// The per-second timer exists purely to drive that readout, so it runs only
    /// while the readout is actually on screen — an hours-long countdown nobody
    /// is looking at is pure idle CPU.
    /// Counted, not a flag: there is one `ClaudeUsageLiveActivity` per screen, so
    /// on a multi-display Mac the views appear and disappear independently. A
    /// plain bool let one view's `onDisappear` stop the ticker while another was
    /// still on screen, freezing that countdown until the next phase change.
    func setCountdownVisible(_ visible: Bool) {
        let was = visibleCountdowns > 0
        visibleCountdowns = max(0, visibleCountdowns + (visible ? 1 : -1))
        let now = visibleCountdowns > 0
        guard was != now else { return }
        if now { refreshRemaining() }
        updateTicker()
    }

    /// Single funnel for phase changes, so the notch visibility flag and the
    /// countdown timer can never drift out of step with the phase.
    private func setPhase(_ phase: Phase) {
        if live.phase != phase { live.phase = phase }

        let visible = phase != .idle && Defaults[.claudeUsageNotifyOnMac]
        if isLiveActivityVisible != visible { isLiveActivityVisible = visible }

        updateTicker()
    }

    private func updateTicker() {
        let shouldRun = live.phase == .limited
            && visibleCountdowns > 0
            && !isSuspended
            && live.resetDate != nil

        if shouldRun {
            startTicker()
        } else {
            stopTicker()
        }
    }

    private func startTicker() {
        guard tickTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + 1,
            repeating: 1.0,
            leeway: .milliseconds(Int(Self.tickTolerance * 1000)))
        timer.setEventHandler {
            MainActor.assumeIsolated {
                ClaudeUsageManager.shared.refreshRemaining()
            }
        }
        timer.resume()
        tickTimer = timer
    }

    private func stopTicker() {
        tickTimer?.cancel()
        tickTimer = nil
    }

    private func refreshRemaining() {
        guard let resetDate = live.resetDate else {
            live.remaining = 0
            return
        }
        live.remaining = max(0, resetDate.timeIntervalSinceNow)
    }

    // MARK: - Presentation

    private func showAlert(icon: String, title: String, subtitle: String, accent: Color) {
        guard Defaults[.claudeUsageNotifyOnMac] else { return }
        DynamicIslandViewCoordinator.shared.toggleSneakPeek(
            status: true,
            type: .claudeUsage,
            duration: Self.alertDuration,
            icon: icon,
            title: title,
            subtitle: subtitle,
            accentColor: accent)
    }

    /// `8:10 pm` in the zone the banner named, which is not necessarily this
    /// machine's zone — showing it in local time would be a lie about what the
    /// transcript said.
    private static func absoluteResetText(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return String(localized: "Resets at \(formatter.string(from: date))")
    }

    private static func shortId(_ sessionId: String) -> String {
        String(sessionId.prefix(8))
    }
}
