import AppKit
import Defaults
import Foundation

enum Logger {
    enum Category { case lifecycle }
    static func log(_ message: String, category: Category) {}
}

@main
struct DailyCommitScheduleTests {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures += 1; print("FAIL: \(message)") }
        }
        let now = Date()
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        Defaults[.gitDailyCommitCount] = 2
        Defaults[.gitDailyCommitRandomCount] = false
        check(GitCommitManager.dailyTarget(on: now) == 2, "fixed count stays unchanged")
        Defaults[.gitDailyCommitRandomCount] = true
        Defaults[.gitDailyCommitCountSeed] = 81273
        Defaults[.gitDailyCommitMinimumCount] = 3
        Defaults[.gitDailyCommitMaximumCount] = 7
        let target = GitCommitManager.dailyTarget(on: now)
        check((3...7).contains(target), "random target is inclusive")
        check(target == GitCommitManager.dailyTarget(on: now), "re-reading today's target is stable")
        Defaults[.gitDailyCommitLastRun] = now
        Defaults[.gitDailyCommitDoneToday] = target - 1
        check(!GitCommitManager.quotaUsedForToday(), "quota allows the last scheduled slot")
        Defaults[.gitDailyCommitDoneToday] = target
        check(GitCommitManager.quotaUsedForToday(), "quota stops at the random target")
        let next = GitCommitManager.shared.nextFireDate(after: now)!
        check(calendar.isDate(next, inSameDayAs: tomorrow), "completed quota schedules tomorrow")
        let tomorrowTarget = GitCommitManager.dailyTarget(on: tomorrow)
        let start = 21.0 * 3600 + 7 * 60
        let end = min(start + 4 * 3600, 24 * 3600 - 60)
        let expectedRandomDay = tomorrow.addingTimeInterval(start + (end - start) / Double(tomorrowTarget) * 0.5)
        check(abs(next.timeIntervalSince(expectedRandomDay)) < 0.001, "tomorrow uses its own target for slot spacing")
        let lateToday = calendar.startOfDay(for: now).addingTimeInterval(20 * 3600)
        Defaults[.gitDailyCommitHour] = 1
        Defaults[.gitDailyCommitMinute] = 0
        Defaults[.gitDailyCommitLastRun] = lateToday
        Defaults[.gitDailyCommitDoneToday] = 1
        let catchUp = GitCommitManager.shared.nextFireDate(after: lateToday)!
        check(catchUp >= lateToday.addingTimeInterval(60), "overdue remaining slots do not fire immediately together")
        Defaults[.gitDailyCommitLastRun] = now
        Defaults[.gitDailyCommitRandomCount] = false
        Defaults[.gitDailyCommitCount] = 1
        Defaults[.gitDailyCommitHour] = 9
        Defaults[.gitDailyCommitMinute] = 17
        Defaults[.gitDailyCommitRandomTime] = false
        Defaults[.gitDailyCommitDoneToday] = 1
        let fixedNext = GitCommitManager.shared.nextFireDate(after: now)!
        let expected = calendar.date(bySettingHour: 9, minute: 17, second: 0, of: tomorrow)!
        check(fixedNext == expected, "tomorrow's single fixed slot uses tomorrow and the configured time")
        Defaults[.gitDailyCommitLastRun] = nil
        let past = calendar.date(bySettingHour: 9, minute: 17, second: 0, of: calendar.startOfDay(for: now))!
        check(GitCommitManager.shared.nextFireDate(after: now) == past, "an overdue slot stays on the current day for catch-up")
        Defaults[.gitDailyCommitRandomCount] = true
        Defaults[.gitDailyCommitMinimumCount] = 0
        Defaults[.gitDailyCommitMaximumCount] = 0
        check(GitCommitManager.quotaUsedForToday(), "a zero target permits no commits")
        check(GitCommitManager.shared.nextFireDate(after: now) == nil, "an all-zero range schedules no timer")
        Defaults[.gitDailyCommitMaximumCount] = 1
        let zeroPair = (0..<90).compactMap { offset -> Date? in
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            return GitCommitManager.dailyTarget(on: day) == 0 && GitCommitManager.dailyTarget(on: next) == 0 ? day : nil
        }.first!
        let zeroTomorrow = calendar.date(byAdding: .day, value: 1, to: zeroPair)!
        let nextCheck = GitCommitManager.shared.nextFireDate(after: zeroPair.addingTimeInterval(12 * 3600))
        check(nextCheck == zeroTomorrow.addingTimeInterval(1), "consecutive zero days schedule a midnight recheck without a commit")
        let temporaryRepo = FileManager.default.temporaryDirectory.appendingPathComponent("anchor-commit-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRepo) }
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
        func git(_ args: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = temporaryRepo
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "DailyCommitTest", code: Int(process.terminationStatus)) }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q"])
        _ = try git(["config", "user.name", "Anchor Test"])
        _ = try git(["config", "user.email", "anchor-test@example.invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        Defaults[.gitDailyCommitRepos] = [temporaryRepo.path]
        Defaults[.gitDailyCommitEnabled] = true
        Defaults[.gitDailyCommitRandomCount] = true
        Defaults[.gitDailyCommitMinimumCount] = 0
        Defaults[.gitDailyCommitMaximumCount] = 0
        Defaults[.gitDailyCommitDoneToday] = 0
        Defaults[.gitDailyCommitLastRun] = nil
        let manager = GitCommitManager.shared
        await manager.performRun(trigger: "test-zero")
        let zeroCommits = try git(["rev-list", "--count", "--all"])
        check(zeroCommits == "0", "a zero target creates no commit in the isolated repository")
        Defaults[.gitDailyCommitMinimumCount] = 1
        Defaults[.gitDailyCommitMaximumCount] = 1
        async let first: Void = manager.performRun(trigger: "test")
        async let second: Void = manager.performRun(trigger: "test")
        _ = await (first, second)
        let commitCount = try git(["rev-list", "--count", "HEAD"])
        check(commitCount == "1", "overlapping callbacks create only one commit in an isolated repository")
        check(Defaults[.gitDailyCommitDoneToday] == 1, "the daily count increments once")
        print("Daily Commit scheduling: \(failures == 0 ? "passed" : "failed")")
        if failures != 0 { exit(1) }
    }
}
