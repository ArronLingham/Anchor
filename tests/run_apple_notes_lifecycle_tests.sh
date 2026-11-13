#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/Defaults.swift" <<'SWIFT'
@_exported import Combine
import Foundation
public enum Defaults {
    public struct Key<Value> {
        public let name: String
        public let defaultValue: Value
        public init(_ name: String, default value: Value) { self.name = name; self.defaultValue = value }
    }
    public protocol Observation: AnyObject {}
    public final class Token: Observation {}
    public enum ObservationOption { case initial }
    private static var values: [String: Any] = [:]
    private static var observers: [String: [() -> Void]] = [:]
    public static subscript<Value>(key: Key<Value>) -> Value {
        get { values[key.name] as? Value ?? key.defaultValue }
        set {
            values[key.name] = newValue
            observers[key.name, default: []].forEach { $0() }
        }
    }
    public static func observe<Value>(_ key: Key<Value>, options: Set<ObservationOption>,
                                      handler: @escaping (Value) -> Void) -> some Observation {
        observers[key.name, default: []].append { handler(self[key]) }
        return Token()
    }
}
extension Defaults.Key where Value == Bool {
    public static var enableNotes: Self { .init("enableNotes", default: false) }
    public static var enableAppleNotesSync: Self { .init("enableAppleNotesSync", default: false) }
}
SWIFT
swiftc -emit-library -emit-module -module-name Defaults "$work/Defaults.swift" -o "$work/libDefaults.dylib"
swiftc -I "$work" -L "$work" -lDefaults -Xlinker -rpath -Xlinker "$work" \
  Anchor/Models/ProductivityWorkflows.swift Anchor/Managers/Productivity/AppleNotesSyncManager.swift \
  tests/AppleNotesSyncLifecycleTests.swift -o "$work/check"
"$work/check"
