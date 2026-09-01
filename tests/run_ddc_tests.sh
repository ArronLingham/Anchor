#!/bin/bash
# Pins DDCPacket — the DDC/CI wire format.
#
# This is the one place in the app that writes bytes to hardware over I2C, and
# it is the least forgiving to debug: the alternative to a test is sending
# malformed packets at someone's monitor and reading the result off the screen.
#
# The single most important assertion here is the null-message case. A monitor
# without DDC/CI answers with length byte 0x80 and an all-zero payload. Reading
# that as a valid reply reports "brightness 0 of 0" AND makes a subsequent write
# look reasonable against a device that is not listening — which is exactly the
# situation on this machine's external monitor, where 12 read attempts across
# three timings all came back null.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Rules.swift" <<'PY'
import re, sys
src = open("Anchor/Managers/Display/ExternalDisplayManager.swift").read()
p = re.search(r'(enum DDCPacket \{.*?\n\})\n', src, re.S).group(1)
open(sys.argv[1], "w").write("import Foundation\n\n" + p + "\n")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

// ---------- get request ----------
let get = DDCPacket.getRequest(.luminance)
ok("get is 5 bytes", get.count == 5, hex(get))
ok("get source byte",  get[0] == 0x51)
ok("get length byte",  get[1] == 0x82)
ok("get opcode",       get[2] == 0x01)
ok("get vcp code",     get[3] == 0x10)
// Checksum: XOR of 0x6E^0x51 with every preceding byte.
var expected: UInt8 = 0x6E ^ 0x51
for b in get[0..<4] { expected ^= b }
ok("get checksum", get[4] == expected, "got \(String(format: "%02X", get[4])), want \(String(format: "%02X", expected))")

// ---------- set request ----------
let set = DDCPacket.setRequest(.luminance, value: 50)
ok("set is 7 bytes", set.count == 7, hex(set))
ok("set length byte", set[1] == 0x84)
ok("set opcode",      set[2] == 0x03)
ok("set vcp code",    set[3] == 0x10)
ok("set high byte",   set[4] == 0x00)
ok("set low byte",    set[5] == 50)

// Big-endian matters: a value over 255 must not lose its high byte. Sending
// only the low byte works for every value under 256 and then silently fails on
// a monitor whose range goes higher.
let big = DDCPacket.setRequest(.luminance, value: 1000)
ok("1000 high byte", big[4] == 0x03, "got \(String(format: "%02X", big[4]))")
ok("1000 low byte",  big[5] == 0xE8, "got \(String(format: "%02X", big[5]))")
let maxv = DDCPacket.setRequest(.luminance, value: 65535)
ok("65535 high byte", maxv[4] == 0xFF)
ok("65535 low byte",  maxv[5] == 0xFF)

// Every set packet's checksum must verify.
for v in [UInt16(0), 1, 50, 100, 255, 256, 1000, 32768, 65535] {
    let p = DDCPacket.setRequest(.luminance, value: v)
    var want: UInt8 = 0x6E ^ 0x51
    for b in p[0..<6] { want ^= b }
    ok("set(\(v)) checksum", p[6] == want)
}

// Different VCP codes are distinguished.
ok("contrast code", DDCPacket.getRequest(.contrast)[3] == 0x12)
ok("volume code",   DDCPacket.getRequest(.volume)[3] == 0x62)
ok("input code",    DDCPacket.getRequest(.inputSource)[3] == 0x60)

// ---------- parseReply: the null-message guard ----------
// This is the actual reply this machine's external monitor returned, verbatim.
let nullReply: [UInt8] = [0x6E, 0x80, 0xBE, 0, 0, 0, 0, 0, 0, 0, 0]
ok("REAL null reply from this Mac's monitor is rejected",
   DDCPacket.parseReply(nullReply, expecting: .luminance) == nil)
// NOTE: the line above is caught by the OPCODE guard, not the length guard —
// 0xBE is the null message's checksum sitting in the opcode position. A
// negative control removing `reply[1] != 0x80` alone left every test green,
// so this case exercises the length guard specifically: zero length declared
// alongside an otherwise plausible payload.
ok("zero-length declared with a valid-looking payload is rejected",
   DDCPacket.parseReply([0x6E, 0x80, 0x02, 0x00, 0x10, 0x00, 0x00, 100, 0x00, 50, 0x00],
                        expecting: .luminance) == nil)

// A well-formed reply: current 50, max 100.
let good: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 100, 0x00, 50, 0x00]
if let r = DDCPacket.parseReply(good, expecting: .luminance) {
    ok("good reply current", r.current == 50, "got \(r.current)")
    ok("good reply max",     r.max == 100, "got \(r.max)")
} else { failures += 1; print("  FAIL good reply rejected") }

// Two-byte values must be assembled big-endian.
let wide: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x03, 0xE8, 0x01, 0xF4, 0x00]
if let r = DDCPacket.parseReply(wide, expecting: .luminance) {
    ok("wide max is 1000",     r.max == 1000, "got \(r.max)")
    ok("wide current is 500",  r.current == 500, "got \(r.current)")
} else { failures += 1; print("  FAIL wide reply rejected") }

// Every malformed shape must be rejected rather than half-read.
ok("wrong opcode rejected",
   DDCPacket.parseReply([0x6E, 0x88, 0x03, 0x00, 0x10, 0, 0, 100, 0, 50, 0], expecting: .luminance) == nil)
ok("error result code rejected",
   DDCPacket.parseReply([0x6E, 0x88, 0x02, 0x01, 0x10, 0, 0, 100, 0, 50, 0], expecting: .luminance) == nil)
ok("reply for a DIFFERENT vcp code rejected",
   DDCPacket.parseReply([0x6E, 0x88, 0x02, 0x00, 0x12, 0, 0, 100, 0, 50, 0], expecting: .luminance) == nil)
ok("zero max rejected",
   DDCPacket.parseReply([0x6E, 0x88, 0x02, 0x00, 0x10, 0, 0, 0, 0, 0, 0], expecting: .luminance) == nil)
ok("short buffer rejected",
   DDCPacket.parseReply([0x6E, 0x88, 0x02], expecting: .luminance) == nil)
ok("empty buffer rejected",
   DDCPacket.parseReply([], expecting: .luminance) == nil)
ok("all zeroes rejected",
   DDCPacket.parseReply([UInt8](repeating: 0, count: 11), expecting: .luminance) == nil)

// current > max is clamped rather than yielding over 100%.
if let r = DDCPacket.parseReply([0x6E, 0x88, 0x02, 0x00, 0x10, 0, 0, 100, 0, 200, 0],
                                expecting: .luminance) {
    ok("current above max is clamped", r.current == 100, "got \(r.current)")
} else { failures += 1; print("  FAIL clamping case rejected outright") }

// ---------- fraction <-> raw ----------
ok("0% of 100",   DDCPacket.rawValue(fraction: 0, max: 100) == 0)
ok("50% of 100",  DDCPacket.rawValue(fraction: 0.5, max: 100) == 50)
ok("100% of 100", DDCPacket.rawValue(fraction: 1, max: 100) == 100)
ok("50% of 65535", DDCPacket.rawValue(fraction: 0.5, max: 65535) == 32768)
ok("negative clamps to 0",   DDCPacket.rawValue(fraction: -1, max: 100) == 0)
ok("above 1 clamps to max",  DDCPacket.rawValue(fraction: 5, max: 100) == 100)
ok("NaN clamps to 0",        DDCPacket.rawValue(fraction: .nan, max: 100) == 0)
ok("infinity clamps to max", DDCPacket.rawValue(fraction: .infinity, max: 100) == 100)

ok("fraction of 50/100", DDCPacket.fraction(raw: 50, max: 100) == 0.5)
ok("fraction of 0/100",  DDCPacket.fraction(raw: 0, max: 100) == 0)
ok("fraction with zero max does not divide by zero",
   DDCPacket.fraction(raw: 50, max: 0) == 0)
ok("fraction above max is clamped to 1", DDCPacket.fraction(raw: 200, max: 100) == 1)

// Round trip must be stable across ranges.
for max in [UInt16(100), 255, 1000, 65535] {
    for pct in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let raw = DDCPacket.rawValue(fraction: pct, max: max)
        let back = DDCPacket.fraction(raw: raw, max: max)
        ok("round trip \(Int(pct*100))% of \(max)", abs(back - pct) < 0.01,
           "got \(back)")
    }
}

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Rules.swift" "$WORK/main.swift" -o "$WORK/ddc" 2>&1 | grep -E "error" || true
"$WORK/ddc"
