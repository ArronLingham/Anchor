/*
 * Cadence
 * Copyright (C) 2026 Cadence Contributors
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

import Foundation

/// Undo for the layout editor.
///
/// Every edit was destructive and the only way back was Reset, which throws away
/// the whole surface. That is a bad trade for a mis-drop: you lose ten minutes
/// of arranging because one element went in the wrong cell.
///
/// Deliberately **not** `UndoManager`. That is tied to a responder chain and to
/// window focus, and the editor lives in a `TabView` inside a window that an
/// accessory app raises by hand — the chain is exactly the thing that already
/// swallowed `showSettingsWindow:`. A plain stack has no such dependency and
/// its behaviour is obvious.
///
/// History is per surface, because the surfaces are independent everywhere else
/// and an undo that jumped you to a different tab would be alarming.
@MainActor
final class LayoutHistory: ObservableObject {
    /// Enough to recover from a bad session, not enough to hold layouts alive
    /// for the life of the app. Each entry is a handful of small structs.
    private static let limit = 50

    private var past: [PlayerSurface: [SurfaceLayout]] = [:]
    private var future: [PlayerSurface: [SurfaceLayout]] = [:]

    /// Bumped on every change so SwiftUI re-evaluates `canUndo` / `canRedo`.
    @Published private(set) var revision = 0

    func canUndo(_ surface: PlayerSurface) -> Bool { !(past[surface]?.isEmpty ?? true) }
    func canRedo(_ surface: PlayerSurface) -> Bool { !(future[surface]?.isEmpty ?? true) }

    /// Call with the state **before** an edit.
    ///
    /// Recording the prior value rather than the new one is what makes a single
    /// `undo()` land where the user expects: back to what they were looking at
    /// when they started the drag.
    func record(_ layout: SurfaceLayout, for surface: PlayerSurface) {
        var stack = past[surface] ?? []
        // A no-op edit is not worth a history entry — dropping an element back
        // where it started would otherwise cost an undo press to get past.
        if stack.last == layout { return }
        stack.append(layout)
        if stack.count > Self.limit { stack.removeFirst(stack.count - Self.limit) }
        past[surface] = stack
        // Any new edit invalidates the redo branch, as it does everywhere else.
        future[surface] = []
        revision &+= 1
    }

    /// Returns the layout to restore, given what is on screen now.
    func undo(_ surface: PlayerSurface, current: SurfaceLayout) -> SurfaceLayout? {
        guard var stack = past[surface], let previous = stack.popLast() else { return nil }
        past[surface] = stack
        future[surface, default: []].append(current)
        revision &+= 1
        return previous
    }

    func redo(_ surface: PlayerSurface, current: SurfaceLayout) -> SurfaceLayout? {
        guard var stack = future[surface], let next = stack.popLast() else { return nil }
        future[surface] = stack
        past[surface, default: []].append(current)
        revision &+= 1
        return next
    }

    func clear(_ surface: PlayerSurface) {
        past[surface] = []
        future[surface] = []
        revision &+= 1
    }
}
