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
import CoreGraphics
import Foundation
import IOKit

// MARK: - Pure: the DDC/CI wire format

/// Builds and validates DDC/CI packets.
///
/// Pure, and worth isolating because the alternative is debugging a checksum by
/// sending malformed I2C at someone's monitor. Every constant here is from the
/// VESA DDC/CI spec, and the reply validation is what stops a null response
/// being read as "brightness 0".
enum DDCPacket {

    /// Standard VCP feature codes.
    enum VCP: UInt8 {
        case luminance = 0x10
        case contrast  = 0x12
        case volume    = 0x62
        case inputSource = 0x60
    }

    /// I2C address DDC/CI uses, and the source address in each packet.
    static let address: UInt32 = 0x37
    static let offset: UInt32 = 0x51
    private static let destination: UInt8 = 0x6E
    private static let source: UInt8 = 0x51

    /// A "get VCP feature" request.
    static func getRequest(_ code: VCP) -> [UInt8] {
        var packet: [UInt8] = [source, 0x82, 0x01, code.rawValue]
        packet.append(checksum(packet, seed: destination ^ source))
        return packet
    }

    /// A "set VCP feature" request.
    ///
    /// The value is big-endian across two bytes, which is the part most easily
    /// got wrong — sending only the low byte works for every value under 256
    /// and then silently fails on a monitor whose range goes higher.
    static func setRequest(_ code: VCP, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [
            source, 0x84, 0x03, code.rawValue,
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
        packet.append(checksum(packet, seed: destination ^ source))
        return packet
    }

    /// DDC/CI checksum: XOR of every byte, seeded with the address pair.
    static func checksum(_ bytes: [UInt8], seed: UInt8) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    /// Parses a get-VCP reply.
    ///
    /// Returns nil for anything that is not a well-formed, successful reply for
    /// the code that was asked about. This is the guard that matters: a monitor
    /// that does not support DDC answers with a **null message** whose length
    /// byte is `0x80` and whose payload is all zeroes. Accepting that would
    /// report "brightness 0 of 0" and, worse, make a set-request look reasonable
    /// against a device that is not listening.
    static func parseReply(_ reply: [UInt8], expecting code: VCP) -> (current: UInt16, max: UInt16)? {
        guard reply.count >= 10 else { return nil }
        // reply[0] is the destination echo, [1] is length | 0x80.
        // Defence in depth, not the primary check. A real null message is
        // `6E 80 BE` — the byte in the opcode position is its checksum, so the
        // opcode guard below already rejects every one seen in practice
        // (verified: removing this line alone changed no test result). It stays
        // because it states the intent, and it does catch a malformed reply
        // that declares zero length while carrying a plausible opcode.
        guard reply[1] != 0x80 else { return nil }
        guard reply[2] == 0x02 else { return nil }        // get-VCP reply opcode
        guard reply[3] == 0x00 else { return nil }        // result code: 0 = ok
        guard reply[4] == code.rawValue else { return nil } // the code we asked for

        let maxValue = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current  = UInt16(reply[8]) << 8 | UInt16(reply[9])
        // A max of zero is not a usable range and means the reply is junk.
        guard maxValue > 0 else { return nil }
        // Some monitors report a current above max after waking; clamp rather
        // than surface a percentage over 100.
        return (min(current, maxValue), maxValue)
    }

    /// Converts a 0–1 fraction to a raw VCP value for a monitor's range.
    static func rawValue(fraction: Double, max: UInt16) -> UInt16 {
        // NaN has no ordering so it must be caught before the clamp, but the
        // infinities do — `isFinite ? x : 0` flattens +infinity to zero, which
        // turns "as bright as possible" into "off". The same mistake was made
        // in `MenuBarReadoutFormatter.percent` and caught by its tests there.
        guard !fraction.isNaN else { return 0 }
        let clamped = Swift.max(0, Swift.min(1, fraction))
        return UInt16((Double(max) * clamped).rounded())
    }

    /// Converts a raw VCP value back to a 0–1 fraction.
    static func fraction(raw: UInt16, max: UInt16) -> Double {
        guard max > 0 else { return 0 }
        return Swift.min(1, Double(raw) / Double(max))
    }
}

// MARK: - Manager

/// Brightness control for external displays over DDC/CI.
///
/// ## Why this exists alongside `DisplayServicesDynamic`
///
/// `DisplayServicesSetBrightness` handles the built-in panel and nothing else.
/// Measured on this machine: `DisplayServicesGetBrightness` returns status 0 on
/// the built-in display and **status 1000** on the attached external one. So a
/// second path is genuinely required for external displays, and DDC/CI over
/// `IOAVService` is the one every brightness utility uses.
///
/// Also measured, and worth recording: **`DisplayServicesGetContrast` and
/// `DisplayServicesSetContrast` do not exist** — `dlsym` returns nil for both
/// on this macOS. The contrast members of `DisplayServicesDynamic` can
/// therefore never do anything.
///
/// ## Not every monitor answers
///
/// DDC/CI is frequently disabled by default in a monitor's own OSD menu, and it
/// often does not survive a hub or a DisplayPort adapter. `probe()` reports
/// whether a display actually answered, and the UI must say so rather than
/// offering a slider that does nothing — a control that silently fails is worse
/// than one that is absent.
///
/// ## Cost
///
/// Nothing at all until a slider is moved or `probe()` is called. No timer, no
/// polling, no service held open.
@MainActor
final class ExternalDisplayManager: ObservableObject {
    static let shared = ExternalDisplayManager()

    struct Display: Identifiable, Equatable {
        let id: CGDirectDisplayID
        let name: String
        let isBuiltin: Bool
        /// Nil until probed; false means it did not answer DDC.
        var supportsDDC: Bool?
        var currentFraction: Double?
    }

    @Published private(set) var displays: [Display] = []
    @Published private(set) var isProbing = false

    private init() {}

    // MARK: IOKit symbols, resolved once

    private typealias CreateWithServiceFn =
        @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn =
        @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    /// `nonisolated(unsafe)` rather than plain `nonisolated`: a dlopen handle is
    /// an `UnsafeMutableRawPointer?`, which is not Sendable. It is written once
    /// here and only ever read afterwards, which is precisely the case the
    /// `(unsafe)` form exists for — the alternative is a lock around a value
    /// that never changes.
    nonisolated(unsafe) private static let iokit = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    nonisolated private static let createWithService: CreateWithServiceFn? =
        dlsym(iokit, "IOAVServiceCreateWithService").map {
            unsafeBitCast($0, to: CreateWithServiceFn.self)
        }
    nonisolated private static let readI2C: I2CFn? =
        dlsym(iokit, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: I2CFn.self) }
    nonisolated private static let writeI2C: I2CFn? =
        dlsym(iokit, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: I2CFn.self) }

    /// Whether the DDC path is even available on this OS build.
    /// `nonisolated`: these are dlsym'd function pointers with no shared mutable
    /// state, read from detached tasks. Main-actor isolation would buy nothing and
    /// only force a hop off the audio/IO path.
    nonisolated static var isAvailable: Bool {
        createWithService != nil && readI2C != nil && writeI2C != nil
    }

    // MARK: Discovery

    func refresh() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        displays = ids.prefix(Int(count)).map { id in
            Display(id: id,
                    name: Self.name(for: id),
                    isBuiltin: CGDisplayIsBuiltin(id) != 0,
                    supportsDDC: nil,
                    currentFraction: nil)
        }
    }

    /// Asks every external display whether it answers DDC.
    ///
    /// Read-only. Nothing is changed on any monitor by probing.
    func probe() async {
        isProbing = true
        defer { isProbing = false }
        refresh()

        for index in displays.indices where !displays[index].isBuiltin {
            let result = await Task.detached(priority: .userInitiated) {
                Self.readLuminance()
            }.value
            displays[index].supportsDDC = result != nil
            displays[index].currentFraction = result.map {
                DDCPacket.fraction(raw: $0.current, max: $0.max)
            }
        }
    }

    /// Sets external display brightness, 0–1.
    ///
    /// Returns false when the display never answered a DDC read. Writing blind
    /// is refused on purpose: without a working read there is no way to restore
    /// what the brightness was, so a failed write leaves the user's monitor
    /// changed with nothing able to put it back.
    @discardableResult
    func setBrightness(_ fraction: Double, on display: Display) -> Bool {
        guard display.supportsDDC == true,
              let service = Self.externalAVService(),
              let write = Self.writeI2C
        else { return false }

        // Re-read the range rather than assuming 100: monitors report anything
        // from 0–100 to 0–65535, and a value scaled to the wrong range is
        // either a no-op or full brightness.
        guard let range = Self.readLuminance() else { return false }
        let raw = DDCPacket.rawValue(fraction: fraction, max: range.max)

        var packet = DDCPacket.setRequest(.luminance, value: raw)
        let status = packet.withUnsafeMutableBytes {
            write(service, DDCPacket.address, DDCPacket.offset,
                  $0.baseAddress!, UInt32($0.count))
        }
        return status == KERN_SUCCESS
    }

    // MARK: DDC plumbing

    nonisolated private static func readLuminance() -> (current: UInt16, max: UInt16)? {
        guard let service = externalAVService(),
              let write = writeI2C, let read = readI2C
        else { return nil }

        // Three attempts: DDC is a slow, lossy bus and a single miss is normal.
        for _ in 0..<3 {
            var request = DDCPacket.getRequest(.luminance)
            let wrote = request.withUnsafeMutableBytes {
                write(service, DDCPacket.address, DDCPacket.offset,
                      $0.baseAddress!, UInt32($0.count))
            }
            guard wrote == KERN_SUCCESS else { usleep(30_000); continue }

            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            let got = reply.withUnsafeMutableBytes {
                read(service, DDCPacket.address, DDCPacket.offset,
                     $0.baseAddress!, UInt32($0.count))
            }
            if got == KERN_SUCCESS,
               let parsed = DDCPacket.parseReply(reply, expecting: .luminance) {
                return parsed
            }
            usleep(30_000)
        }
        return nil
    }

    /// The AV service for the first external display.
    ///
    /// `Location == "Embedded"` is the built-in panel, which has no DDC bus —
    /// sending it I2C is meaningless, so it is filtered here rather than
    /// relying on the read failing.
    nonisolated private static func externalAVService() -> CFTypeRef? {
        guard let create = createWithService else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            let location = IORegistryEntryCreateCFProperty(
                service, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if location == "External" {
                let ref = create(kCFAllocatorDefault, service)?.takeRetainedValue()
                IOObjectRelease(service)
                return ref
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    nonisolated private static func name(for id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               number == id {
                return screen.localizedName
            }
        }
        return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "External Display"
    }
}
