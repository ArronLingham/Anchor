#!/bin/bash
# Pins the URL cleaner's behaviour.
#
# This is worth a harness for the same reason the colour formats are: a wrong
# rule here is *invisible* — the link still looks like a link, it just silently
# stops working, or a tracking parameter silently survives. Both failures are
# quiet, so they need pinning rather than eyeballing.
#
# Compiles the real `cleaned(urlString:)` out of ClipboardToolsManager, so the
# test cannot drift from the implementation.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Extract just the pure function and its tables — the rest of the manager pulls
# in AppKit, Defaults and ClipboardManager, none of which this needs.
python3 - "$WORK/UrlClean.swift" <<'PY'
import re, sys
src = open("Anchor/Managers/Clipboard/ClipboardToolsManager.swift").read()

prefixes = re.search(r'private static let trackingPrefixes = (\[.*?\])', src, re.S).group(1)
params = re.search(r'private static let trackingParameters: Set<String> = (\[.*?\n    \])', src, re.S).group(1)
func = re.search(r'(    static func cleaned\(urlString: String\) -> String\? \{.*?\n    \})', src, re.S).group(1)

out = f"""import Foundation

enum URLCleaner {{
    static let trackingPrefixes = {prefixes}
    static let trackingParameters: Set<String> = {params}
{func.replace("trackingParameters", "Self.trackingParameters").replace("trackingPrefixes", "Self.trackingPrefixes")}
}}

var failures = 0
var passes = 0

func check(_ label: String, _ input: String, _ expected: String?) {{
    let got = URLCleaner.cleaned(urlString: input)
    if got == expected {{
        passes += 1
    }} else {{
        failures += 1
        print("  FAIL \\(label)")
        print("       in:  \\(input)")
        print("       got: \\(got ?? "nil")")
        print("       want:\\(expected ?? "nil")")
    }}
}}

// --- tracking parameters are removed ---
check("utm_source", "https://x.com/a?utm_source=news", "https://x.com/a")
check("utm family", "https://x.com/a?utm_source=n&utm_medium=e&utm_campaign=c", "https://x.com/a")
check("fbclid", "https://x.com/a?fbclid=abc", "https://x.com/a")
check("gclid", "https://x.com/a?gclid=abc", "https://x.com/a")
check("igshid", "https://instagram.com/p/1?igshid=xyz", "https://instagram.com/p/1")
check("mixed, keeps real", "https://x.com/a?id=7&utm_source=n", "https://x.com/a?id=7")
check("case-insensitive", "https://x.com/a?UTM_SOURCE=n", "https://x.com/a")

// --- links that must NOT be altered ---
check("no query", "https://x.com/a", nil)
check("only real params", "https://x.com/a?id=7&page=2", nil)
check("youtube v= survives", "https://youtube.com/watch?v=abc123", nil)
check("search q= survives", "https://google.com/search?q=hello", nil)
check("fragment kept", "https://x.com/a?utm_source=n#section", "https://x.com/a#section")

// --- structure is preserved ---
check("port kept", "https://x.com:8443/a?utm_source=n", "https://x.com:8443/a")
check("path kept", "https://x.com/deep/path/here?fbclid=1", "https://x.com/deep/path/here")
check("multiple real kept in order", "https://x.com/a?b=1&utm_source=n&c=2", "https://x.com/a?b=1&c=2")

// --- malformed / edge input must not crash or mangle ---
check("empty", "", nil)
check("not a url", "hello world", nil)
check("scheme only", "https://", nil)
check("trailing ? only", "https://x.com/a?", nil)

if failures == 0 {{
    print("\\(passes)/\\(passes) passed")
    exit(0)
}} else {{
    print("\\(passes) passed, \\(failures) failed")
    exit(1)
}}
"""
open(sys.argv[1], "w").write(out)
PY

swiftc -O "$WORK/UrlClean.swift" -o "$WORK/urlclean" 2>&1 | grep -v "^$" || true
"$WORK/urlclean"
