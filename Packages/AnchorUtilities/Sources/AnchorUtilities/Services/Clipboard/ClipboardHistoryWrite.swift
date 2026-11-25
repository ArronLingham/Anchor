// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

protocol ClipboardHistoryPasteboard {
    func clearContents() -> Int
    var changeCount: Int { get }
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
    func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: ClipboardHistoryPasteboard {}

struct ClipboardHistoryWriteResult {
    let succeeded: Bool
    let changeCount: Int
}

enum ClipboardHistoryWrite {
    case text(String)
    case image(png: Data, tiff: Data?)
    case files([NSURL])
    case rich(NSAttributedString, plain: String)

    /// Expiry stops subsequent writes. Once cleared, always read the final
    /// change count so history can exclude our mutation, even after timeout.
    /// Authorization is checked before starting. Once accepted, finish the
    /// write even if the feature leaves the current session.
    func write(to pasteboard: any ClipboardHistoryPasteboard,
               isExpired: () -> Bool,
               isAuthorized: () -> Bool = { true }) -> ClipboardHistoryWriteResult? {
        guard !isExpired(), isAuthorized() else { return nil }
        _ = pasteboard.clearContents()

        var succeeded = false
        if !isExpired() {
            switch self {
            case let .text(text):
                succeeded = pasteboard.setString(text, forType: .string)
            case let .image(png, tiff):
                succeeded = pasteboard.setData(png, forType: .png)
                if succeeded, let tiff, !isExpired() {
                    _ = pasteboard.setData(tiff, forType: .tiff)
                }
            case let .files(urls):
                succeeded = pasteboard.writeObjects(urls)
            case let .rich(rich, plain):
                succeeded = pasteboard.writeObjects([rich])
                if succeeded, !plain.isEmpty, !isExpired() {
                    _ = pasteboard.setString(plain, forType: .string)
                }
            }
        }

        let changeCount = pasteboard.changeCount
        return ClipboardHistoryWriteResult(succeeded: !isExpired() && succeeded,
                                           changeCount: changeCount)
    }
}
