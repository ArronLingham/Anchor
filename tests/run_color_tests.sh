#!/usr/bin/env bash
#
# Compiles the real models/PickedColor.swift and checks the eight format
# strings the colour picker copies to the clipboard.
#
# PickedColor does `import Defaults` for its preference-storage conformance.
# A stub *file* cannot satisfy an import — that needs a module — so the stub is
# first compiled into one literally named `Defaults`. This is the difference
# from LoggerStub, which works as a plain file because Logger is a type in the
# same module rather than an import. SwiftUI and AppKit are system frameworks
# and need no stub.
#
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$repo/Anchor/models/PickedColor.swift"
stub="$repo/tests/support/DefaultsStub.swift"
test_src="$repo/tests/ColorFormatTests.swift"

for f in "$src" "$stub" "$test_src"; do
  [[ -f "$f" ]] || { echo "missing source: $f" >&2; exit 1; }
done

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# The module interface alone is not enough — the protocol descriptor has to
# exist at link time too, so emit an object file and link it as well.
swiftc -emit-module -module-name Defaults \
  -emit-module-path "$out/Defaults.swiftmodule" "$stub"
swiftc -c -parse-as-library -module-name Defaults -o "$out/Defaults.o" "$stub"

swiftc -O -I "$out" "$src" "$test_src" "$out/Defaults.o" -o "$out/colortests"
"$out/colortests"
