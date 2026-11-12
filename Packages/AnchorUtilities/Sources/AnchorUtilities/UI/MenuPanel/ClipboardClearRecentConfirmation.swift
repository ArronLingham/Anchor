// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct ClipboardClearRecentRequest {
    let entryIDs: [UUID: Date]
    let ticket: UUID

    static func capture(_ entryIDs: [UUID: Date]) -> Self? {
        guard let ticket = ClipboardHistoryService.availabilityTicket() else { return nil }
        return Self(entryIDs: entryIDs, ticket: ticket)
    }

    func performIfCurrent(accepts: (UUID) -> Bool, clear: ([UUID: Date]) -> Void) {
        guard accepts(ticket) else { return }
        clear(entryIDs)
    }

    func perform() {
        performIfCurrent(accepts: ClipboardHistoryService.acceptsAvailabilityTicket) { ids in
            ClipboardHistoryService.shared.clearRecent(ids)
        }
    }
}

/// Asks before "Clear unpinned" deletes anything. The button stores the
/// unpinned entries it saw, and only those are deleted.
struct ClipboardClearRecentConfirmation: ViewModifier {
    @Binding var request: ClipboardClearRecentRequest?
    @ObservedObject private var l10n = L10n.shared

    func body(content: Content) -> some View {
        let text = FeatureStrings.clipboard(l10n.language)
        content.alert(String(format: text.clearRecentConfirmFormat, request?.entryIDs.count ?? 0),
                      isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                      presenting: request) { request in
            Button(text.cancel, role: .cancel) {}
            Button(text.clearRecent, role: .destructive) {
                request.perform()
            }
        } message: { _ in
            Text(text.clearRecentConfirmMessage)
        }
    }
}
