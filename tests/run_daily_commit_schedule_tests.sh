#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/Defaults.swift" <<'SWIFT'
@_exported import Combine
import Foundation
public protocol DefaultsAnyKey { var name: String { get } }
public enum Defaults {
    public struct Key<Value>: DefaultsAnyKey {
        public let name: String
        public let defaultValue: Value
        public init(_ name: String, default value: Value) { self.name = name; self.defaultValue = value }
    }
    private static var values: [String: Any] = [:]
    private static let lock = NSRecursiveLock()
    public static subscript<Value>(key: Key<Value>) -> Value {
        get { lock.lock(); defer { lock.unlock() }; return values[key.name] as? Value ?? key.defaultValue }
        set { lock.lock(); defer { lock.unlock() }; values[key.name] = newValue as Any }
    }
    public static func publisher(keys: Key<Bool>, _ hour: Key<Int>, _ minute: Key<Int>,
                                 _ count: Key<Int>, _ random: Key<Bool>, _ minimum: Key<Int>,
                                 _ maximum: Key<Int>, _ randomTime: Key<Bool>,
                                 _ start: Key<Int>, _ end: Key<Int>, _ repos: Key<[String]>) -> AnyPublisher<Void, Never> {
        Empty().eraseToAnyPublisher()
    }
}
extension Defaults.Key where Value == Bool {
    public static var gitDailyCommitEnabled: Self { .init("enabled", default: false) }
    public static var gitDailyCommitRandomCount: Self { .init("randomCount", default: false) }
    public static var gitDailyCommitRandomTime: Self { .init("randomTime", default: false) }
    public static var gitDailyCommitRandomMessage: Self { .init("randomMessage", default: false) }
    public static var gitDailyCommitStageChanges: Self { .init("stage", default: false) }
    public static var gitDailyCommitPush: Self { .init("push", default: false) }
}
extension Defaults.Key where Value == Int {
    public static var gitDailyCommitCount: Self { .init("count", default: 1) }
    public static var gitDailyCommitMinimumCount: Self { .init("min", default: 1) }
    public static var gitDailyCommitMaximumCount: Self { .init("max", default: 3) }
    public static var gitDailyCommitCountSeed: Self { .init("seed", default: 0) }
    public static var gitDailyCommitDoneToday: Self { .init("done", default: 0) }
    public static var gitDailyCommitHour: Self { .init("hour", default: 21) }
    public static var gitDailyCommitMinute: Self { .init("minute", default: 7) }
    public static var gitDailyCommitWindowStartHour: Self { .init("windowStart", default: 9) }
    public static var gitDailyCommitWindowEndHour: Self { .init("windowEnd", default: 22) }
}
extension Defaults.Key where Value == Date? {
    public static var gitDailyCommitLastRun: Self { .init("last", default: nil) }
}
extension Defaults.Key where Value == [String] {
    public static var gitDailyCommitRepos: Self { .init("repos", default: []) }
}
extension Defaults.Key where Value == String {
    public static var gitDailyCommitMessage: Self { .init("message", default: "test") }
}
SWIFT
swiftc -emit-library -emit-module -module-name Defaults "$work/Defaults.swift" -o "$work/libDefaults.dylib"
swiftc -I "$work" -L "$work" -lDefaults -Xlinker -rpath -Xlinker "$work" \
  Anchor/Models/ProductivityWorkflows.swift Anchor/Managers/Productivity/GitCommitManager.swift \
  tests/DailyCommitScheduleTests.swift -o "$work/check"
"$work/check"
