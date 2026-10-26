#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
# Only serialization's marker protocol is needed by these pure layout tests.
printf 'public enum Defaults { public protocol Serializable {} }\n' > "$task_tmp/Defaults.swift"
swiftc -emit-module -emit-library -static -o "$task_tmp/libDefaults.a" -module-name Defaults "$task_tmp/Defaults.swift" -emit-module-path "$task_tmp/Defaults.swiftmodule"
swiftc -I "$task_tmp" -L "$task_tmp" -lDefaults Anchor/Components/Music/CadenceLayout/{PlayerElement,SurfaceLayout,DefaultLayouts,GridSolver}.swift tests/FullscreenLayoutTests.swift -o "$task_tmp/tests"
"$task_tmp/tests"
