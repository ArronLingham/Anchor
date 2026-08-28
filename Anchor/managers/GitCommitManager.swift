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

import AppKit
import Combine
import Defaults
import Foundation

/// Makes one commit a day in each configured repository.
///
/// ## What it commits
///
/// By default, **an empty commit** (`git commit --allow-empty`). That is the
/// honest form of "a commit a day whether or not there was work": it records a
/// dated marker without inventing a file, and it leaves the tree byte-identical
/// to what it was. Staging real changes is available but off, because
/// `git add -A` run unattended at 21:07 will eventually sweep in a half-finished
/// edit, a stray build artefact or a secret, and the user would not be at the
/// keyboard to notice.
///
/// ## What it will not do
///
/// - **It will not push unless explicitly switched on**, and that switch is off
///   by default. Committing is local and reversible; pushing is not.
/// - It refuses any repository that is mid-rebase, mid-merge, mid-cherry-pick or
///   on a detached HEAD, because a commit there lands somewhere the user did not
///   choose.
/// - It never sets an author. Anchor's own repository sets that locally, and
///   overriding it here would silently rewrite whose commit it is.
///
/// ## Scheduling
///
/// One `DispatchSourceTimer`, armed for the next due moment and re-armed after
/// it fires — the "schedule, do not poll" rule. A Mac asleep at the scheduled
/// time misses the fire, so `catchUpIfNeeded()` runs at launch and on wake, and
/// commits then if today's is still outstanding.
@MainActor
final class GitCommitManager: ObservableObject {
    static let shared = GitCommitManager()

    struct RunRecord: Equatable {
        let repo: String
        let succeeded: Bool
        let detail: String
    }

    @Published private(set) var lastRunAt: Date?
    @Published private(set) var lastResults: [RunRecord] = []
    @Published private(set) var nextRunAt: Date?
    @Published private(set) var isRunning = false

    private var timer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {
        lastRunAt = Defaults[.gitDailyCommitLastRun]
    }

    // MARK: - Lifecycle

    /// Arms the schedule. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true

        Defaults.publisher(
            keys: .gitDailyCommitEnabled, .gitDailyCommitHour, .gitDailyCommitMinute
        )
        .sink { [weak self] _ in
            Task { @MainActor in self?.reschedule() }
        }
        .store(in: &cancellables)

        // A Mac that was asleep at the scheduled minute never got the fire.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchUpIfNeeded() }
        }

        reschedule()
        catchUpIfNeeded()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        nextRunAt = nil
    }

    // MARK: - Schedule

    private func reschedule() {
        timer?.cancel()
        timer = nil
        nextRunAt = nil

        guard Defaults[.gitDailyCommitEnabled] else { return }
        guard let next = nextFireDate(after: Date()) else { return }

        nextRunAt = next
        let delay = max(1, next.timeIntervalSinceNow)

        // The timer and the git work both live off the main queue. Running a
        // subprocess — `git push` can take tens of seconds — from the main
        // actor would be wrong anyway, and it also means a busy or blocked UI
        // cannot cause a missed day.
        let source = DispatchSource.makeTimerSource(queue: Self.workQueue)
        // Generous leeway: this is a once-a-day housekeeping job, so letting the
        // system coalesce it with other work is free.
        source.schedule(deadline: .now() + delay, leeway: .seconds(60))
        source.setEventHandler { [weak self] in
            Task.detached { [weak self] in
                await self?.performRun(trigger: "schedule")
                // Fire-and-forget for the same reason as the spinner: the next
                // day's schedule must not hinge on the UI being free right now.
                Task { @MainActor in self?.reschedule() }
            }
        }
        timer = source
        source.resume()
    }

    /// When the next commit is due.
    ///
    /// Three cases, in order of how much the user asked for:
    ///
    /// - **Fixed time, one a day** — the original behaviour, the scheduled
    ///   hour and minute.
    /// - **More than one a day** — the remaining commits are spread evenly
    ///   through what is left of the window, so a count of four does not fire
    ///   four times in the same minute.
    /// - **Randomised** — a time drawn inside the window. Drawn once per slot
    ///   rather than re-rolled on every reschedule, or the target would move
    ///   every time anything touched the settings.
    private func nextFireDate(after date: Date) -> Date? {
        let calendar = Calendar.current
        let perDay = max(1, Defaults[.gitDailyCommitCount])
        let doneToday = commitsDoneToday()

        guard doneToday < perDay else {
            // Everything for today is done; the next one is tomorrow's first.
            guard let tomorrow = calendar.date(
                byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            else { return nil }
            return firstSlot(on: tomorrow)
        }

        if Defaults[.gitDailyCommitRandomTime] || perDay > 1 {
            return slot(index: doneToday, of: perDay, on: date) ?? {
                guard let tomorrow = calendar.date(
                    byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
                else { return nil }
                return firstSlot(on: tomorrow)
            }()
        }

        var components = DateComponents()
        components.hour = Defaults[.gitDailyCommitHour]
        components.minute = Defaults[.gitDailyCommitMinute]
        components.second = 0
        return calendar.nextDate(
            after: date, matching: components, matchingPolicy: .nextTime)
    }

    /// The `index`-th of `count` slots on the day containing `reference`,
    /// or nil when that slot has already passed.
    private func slot(index: Int, of count: Int, on reference: Date) -> Date? {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: reference)
        let (start, end) = window()

        guard end > start else { return nil }
        let span = end - start
        // Evenly spaced, offset by half a step so the first is not exactly at
        // the window's edge.
        let step = span / Double(count)
        var offset = start + step * (Double(index) + 0.5)

        if Defaults[.gitDailyCommitRandomTime] {
            // Jitter inside this slot only, so the ordering of slots holds and
            // two commits cannot swap places.
            let jitter = Double(deterministicJitter(day: day, index: index)) / 1000.0
            offset = start + step * (Double(index) + jitter)
        }

        let candidate = day.addingTimeInterval(offset)
        return candidate > reference ? candidate : nil
    }

    private func firstSlot(on day: Date) -> Date? {
        let perDay = max(1, Defaults[.gitDailyCommitCount])
        return slot(index: 0, of: perDay, on: day.addingTimeInterval(-1))
    }

    /// Seconds from midnight for the start and end of the allowed window.
    private func window() -> (Double, Double) {
        if Defaults[.gitDailyCommitRandomTime] {
            let startHour = min(Defaults[.gitDailyCommitWindowStartHour],
                                Defaults[.gitDailyCommitWindowEndHour])
            let endHour = max(Defaults[.gitDailyCommitWindowStartHour],
                              Defaults[.gitDailyCommitWindowEndHour])
            return (Double(startHour) * 3600, Double(endHour) * 3600)
        }
        // Fixed time with several commits: start at the scheduled time and run
        // to the end of the day.
        let start = Double(Defaults[.gitDailyCommitHour]) * 3600
            + Double(Defaults[.gitDailyCommitMinute]) * 60
        return (start, min(start + 4 * 3600, 24 * 3600 - 60))
    }

    /// A jitter in [0, 1) that is stable for a given day and slot.
    ///
    /// Stable on purpose: `Double.random` would redraw the target every time
    /// anything rescheduled, so the commit time would drift all day and could
    /// be skipped entirely by landing behind `now` each time.
    private func deterministicJitter(day: Date, index: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(Int(day.timeIntervalSince1970))
        hasher.combine(index)
        return abs(hasher.finalize()) % 1000
    }

    /// How many commits have already happened today.
    private func commitsDoneToday() -> Int {
        guard let last = Defaults[.gitDailyCommitLastRun],
              Calendar.current.isDateInToday(last)
        else { return 0 }
        return Defaults[.gitDailyCommitDoneToday]
    }

    /// Runs now when a commit for today is still outstanding and its time has
    /// passed.
    ///
    /// Uses the same window as the scheduler rather than the raw hour/minute,
    /// so a randomised or multi-commit day catches up correctly after the Mac
    /// has been asleep or the app was not running.
    func catchUpIfNeeded() {
        guard Defaults[.gitDailyCommitEnabled] else { return }
        guard !Self.quotaUsedForToday() else { return }

        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        let (start, _) = window()
        let earliest = day.addingTimeInterval(start)
        guard earliest <= Date() else { return }

        Task.detached { [weak self] in
            await self?.performRun(trigger: "catch-up")
        }
    }

    /// Whether today's quota of commits is already used up.
    ///
    /// Reads `Defaults` rather than the published property: `performRun` writes
    /// from a background task and only publishes afterwards, so the published
    /// value can lag. Defaults is the authority.
    nonisolated static func quotaUsedForToday() -> Bool {
        guard let last = Defaults[.gitDailyCommitLastRun],
              Calendar.current.isDateInToday(last)
        else { return false }
        return Defaults[.gitDailyCommitDoneToday] >= max(1, Defaults[.gitDailyCommitCount])
    }

    var hasRunToday: Bool { Self.quotaUsedForToday() }

    // MARK: - Running

    /// The queue every git subprocess and every schedule fire runs on.
    ///
    /// Deliberately not the main queue. A `git push` can take tens of seconds,
    /// and a scheduled housekeeping job must not be able to miss its day
    /// because the UI layer was busy.
    private static let workQueue = DispatchQueue(
        label: "com.arronlingham.Anchor.gitcommit", qos: .utility)

    /// Commits in every configured repository.
    ///
    /// `force` is what the settings button passes: it skips the once-a-day
    /// guard so the user can see the thing work without waiting until 21:07.
    ///
    /// Deliberately `nonisolated`: it reads its configuration straight from
    /// `Defaults` (which is `UserDefaults`, safe from any thread) and only hops
    /// to the main actor to publish what happened. The commit itself therefore
    /// does not depend on the main actor being free.
    nonisolated func performRun(trigger: String, force: Bool = false) async {
        // Re-entry is prevented by the day stamp below rather than by a lock:
        // the counter is written to Defaults the moment the work finishes, so a
        // caller that would exceed today's quota returns here.
        if !force, Self.quotaUsedForToday() {
            return
        }

        let repos = Defaults[.gitDailyCommitRepos]
        guard !repos.isEmpty else {
            Task { @MainActor in
                self.publish(
                    records: [RunRecord(
                        repo: "—", succeeded: false,
                        detail: String(localized: "No repositories configured"))],
                    stamp: false)
            }
            return
        }

        // Fire-and-forget rather than `await MainActor.run`. Awaiting the main
        // actor here would make the commit itself depend on the UI being free,
        // and a housekeeping job must not be able to miss its day because
        // something upstream is busy. The spinner is cosmetic; the commit is not.
        Task { @MainActor in self.isRunning = true }

        var records: [RunRecord] = []
        for path in repos {
            records.append(await commit(in: path))
        }

        // Stamp the day *before* publishing, and straight into Defaults, so a
        // main actor that never drains cannot cause the same day to be
        // committed twice on the next launch.
        let now = Date()
        // Reset the counter when this is the first commit of a new day, so a
        // quota of four does not carry yesterday's tally into today.
        let carriedOver = Defaults[.gitDailyCommitLastRun]
            .map { Calendar.current.isDateInToday($0) } ?? false
        Defaults[.gitDailyCommitDoneToday] = (carriedOver ? Defaults[.gitDailyCommitDoneToday] : 0) + 1
        Defaults[.gitDailyCommitLastRun] = now

        Logger.log(
            "Daily commit (\(trigger)): \(records.filter(\.succeeded).count)/\(records.count) repos",
            category: .lifecycle)

        Task { @MainActor in self.publish(records: records, stamp: true, at: now) }
    }

    /// Mirrors the outcome into the published properties the settings pane
    /// reads. Cosmetic only — the commit has already happened by here.
    private func publish(records: [RunRecord], stamp: Bool, at date: Date = Date()) {
        lastResults = records
        if stamp { lastRunAt = date }
        isRunning = false
    }

    /// Main-actor entry point for the settings pane's "Commit Now" button.
    func run(trigger: String, force: Bool = false) async {
        await performRun(trigger: trigger, force: force)
    }

    private nonisolated func commit(in path: String) async -> RunRecord {
        let name = (path as NSString).lastPathComponent

        guard FileManager.default.fileExists(atPath: path) else {
            return RunRecord(repo: name, succeeded: false,
                             detail: String(localized: "Folder is missing"))
        }

        // Is it a work tree at all?
        let inside = await git(["rev-parse", "--is-inside-work-tree"], in: path)
        guard inside.status == 0, inside.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else {
            return RunRecord(repo: name, succeeded: false,
                             detail: String(localized: "Not a git repository"))
        }

        // Refuse anything mid-operation, and refuse a detached HEAD: a commit in
        // either lands somewhere the user did not choose.
        let branch = await git(["symbolic-ref", "--short", "-q", "HEAD"], in: path)
        let branchName = branch.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branch.status == 0, !branchName.isEmpty else {
            return RunRecord(repo: name, succeeded: false,
                             detail: String(localized: "Detached HEAD — skipped"))
        }

        let gitDir = await git(["rev-parse", "--git-dir"], in: path)
        let gitDirPath = gitDir.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedGitDir = gitDirPath.hasPrefix("/")
            ? gitDirPath
            : (path as NSString).appendingPathComponent(gitDirPath)
        for marker in ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "BISECT_LOG"] {
            let markerPath = (resolvedGitDir as NSString).appendingPathComponent(marker)
            if FileManager.default.fileExists(atPath: markerPath) {
                return RunRecord(repo: name, succeeded: false,
                                 detail: String(localized: "Mid-operation — skipped"))
            }
        }

        let message = renderedMessage()
        var committedRealWork = false

        if Defaults[.gitDailyCommitStageChanges] {
            let status = await git(["status", "--porcelain"], in: path)
            if !status.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let add = await git(["add", "-A"], in: path)
                guard add.status == 0 else {
                    return RunRecord(repo: name, succeeded: false,
                                     detail: String(localized: "git add failed"))
                }
                committedRealWork = true
            }
        }

        // --allow-empty covers both paths: nothing staged, or staged changes
        // that turn out to be a no-op.
        let commit = await git(["commit", "--allow-empty", "-m", message], in: path)
        guard commit.status == 0 else {
            return RunRecord(
                repo: name, succeeded: false,
                detail: firstLine(commit.err.isEmpty ? commit.out : commit.err))
        }

        var detail = committedRealWork
            ? String(localized: "Committed changes on \(branchName)")
            : String(localized: "Empty commit on \(branchName)")

        if Defaults[.gitDailyCommitPush] {
            let push = await git(["push"], in: path)
            detail += push.status == 0
                ? String(localized: ", pushed")
                : String(localized: ", push failed")
        }

        return RunRecord(repo: name, succeeded: true, detail: detail)
    }

    /// The commit message, with `{date}` and `{time}` substituted.
    ///
    /// Deliberately carries no co-author trailer. Anchor's repository convention
    /// is that commits have none, and a scheduled job is the last place to start
    /// adding one.
    /// Messages used when "vary the message" is on.
    ///
    /// Deliberately dull and repository-agnostic: the commits are empty, so a
    /// message implying real work would be a small lie in the log for ever.
    /// These say what actually happened.
    nonisolated static let messagePool: [String] = [
        "chore: daily checkpoint",
        "chore: routine checkpoint",
        "chore: housekeeping",
        "chore: keep the lights on",
        "chore: end-of-day marker",
        "chore: no changes today",
        "chore: periodic checkpoint",
        "chore: daily marker",
        "chore: nothing to report",
        "chore: routine sweep",
        "chore: scheduled checkpoint",
        "chore: quiet day",
    ]

    nonisolated func renderedMessage(now: Date = Date()) -> String {
        let template = Defaults[.gitDailyCommitRandomMessage]
            ? (Self.messagePool.randomElement() ?? Defaults[.gitDailyCommitMessage])
            : Defaults[.gitDailyCommitMessage]
        let date = now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let time = now.formatted(date: .omitted, time: .shortened)
        return template
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{time}", with: time)
    }

    private nonisolated func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init)
            ?? String(localized: "Unknown error")
    }

    // MARK: - git

    /// Runs git in `directory` and returns its output.
    ///
    /// Off the main thread, with a hard timeout — a `git push` against an
    /// unreachable host, or one that decides to prompt for credentials, would
    /// otherwise hang this actor for ever. `GIT_TERMINAL_PROMPT=0` and
    /// `SSH_ASKPASS` are set so it fails fast rather than waiting on a prompt
    /// that no one can see.
    private nonisolated func git(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = 60
    ) async -> (status: Int32, out: String, err: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: directory)

                var environment = ProcessInfo.processInfo.environment
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["GIT_ASKPASS"] = "/usr/bin/true"
                environment["SSH_ASKPASS"] = "/usr/bin/true"
                environment["GIT_OPTIONAL_LOCKS"] = "0"
                process.environment = environment

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, "", error.localizedDescription))
                    return
                }

                // Read before waiting: a pipe that fills up blocks the child,
                // which would then never exit and defeat the timeout below.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning, Date() < deadline {
                    usleep(50_000)
                }
                if process.isRunning {
                    process.terminate()
                    continuation.resume(returning: (-1, "", "timed out"))
                    return
                }

                continuation.resume(returning: (
                    process.terminationStatus,
                    String(decoding: outData, as: UTF8.self),
                    String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}
