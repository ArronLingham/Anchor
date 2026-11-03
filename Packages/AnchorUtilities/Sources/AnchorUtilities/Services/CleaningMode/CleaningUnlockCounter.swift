// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Pure state for a continuous Escape hold, separate from event-tap timing.
struct CleaningEscapeHold {
    let requiredKeyCode: Int64
    let duration: TimeInterval
    private(set) var pressedSince: TimeInterval?

    mutating func keyDown(code: Int64, time: TimeInterval, isRepeat: Bool) {
        guard code == requiredKeyCode else { reset(); return }
        if !isRepeat && pressedSince == nil { pressedSince = time }
    }

    mutating func keyUp(code: Int64) {
        if code == requiredKeyCode { reset() }
    }

    func elapsed(at time: TimeInterval) -> TimeInterval { pressedSince.map { max(0, time - $0) } ?? 0 }
    func isComplete(at time: TimeInterval) -> Bool { pressedSince != nil && elapsed(at: time) >= duration }
    mutating func reset() { pressedSince = nil }
}

struct CleaningSystemKeyEvent: Equatable {
    static let systemDefinedEventTypeRawValue: UInt32 = 14
    static let powerKeySubtype = 1
    static let auxiliaryControlButtonsSubtype = 8
    static let keyDownState = 10
    static let keyUpState = 11

    private static let syntheticKeyCodeBase: Int64 = 10_000

    let code: Int64
    let isKeyDown: Bool
    let isRepeat: Bool

    static func decode(subtype: Int, data1: Int) -> CleaningSystemKeyEvent? {
        switch subtype {
        case auxiliaryControlButtonsSubtype:
            return decodeAuxiliaryControl(data1: data1)
        case powerKeySubtype:
            return CleaningSystemKeyEvent(code: syntheticKeyCodeBase + Int64(powerKeySubtype),
                                          isKeyDown: true,
                                          isRepeat: false)
        default:
            return nil
        }
    }

    private static func decodeAuxiliaryControl(data1: Int) -> CleaningSystemKeyEvent? {
        let raw = UInt32(truncatingIfNeeded: data1)
        let keyCode = Int64((raw >> 16) & 0xffff)
        let state = Int((raw >> 8) & 0xff)
        guard state == keyDownState || state == keyUpState else { return nil }
        return CleaningSystemKeyEvent(code: syntheticKeyCodeBase + keyCode,
                                      isKeyDown: state == keyDownState,
                                      isRepeat: (raw & 0x1) != 0)
    }
}
