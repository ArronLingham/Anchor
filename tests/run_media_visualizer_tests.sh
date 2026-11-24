#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
cat > "$task_tmp/Defaults.swift" <<'SWIFT'
public enum Defaults {
    public struct Key<Value> {
        let name: String
        let defaultValue: Value

        public init(_ name: String, default defaultValue: Value) {
            self.name = name
            self.defaultValue = defaultValue
        }
    }

    private static var values: [String: Any] = [:]

    public static subscript<Value>(key: Key<Value>) -> Value {
        get { values[key.name] as? Value ?? key.defaultValue }
        set { values[key.name] = newValue }
    }
}

@propertyWrapper
public struct Default<Value> {
    let key: Defaults.Key<Value>
    public init(_ key: Defaults.Key<Value>) { self.key = key }
    public var wrappedValue: Value { Defaults[key] }
}
SWIFT
swiftc -emit-module -emit-library -static -o "$task_tmp/libDefaults.a" -module-name Defaults \
  "$task_tmp/Defaults.swift" -emit-module-path "$task_tmp/Defaults.swiftmodule"
swiftc -I "$task_tmp" -L "$task_tmp" -lDefaults \
  Anchor/Components/Music/MusicVisualizer.swift Anchor/Audio/RealTimeAudioSpectrum.swift \
  tests/MediaVisualizerTests.swift -o "$task_tmp/tests"
"$task_tmp/tests"
