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

import Defaults
import Foundation
import SwiftUI

/// One line on the to-do list.
///
/// Deliberately *not* an `EKReminder`. Anchor already reads Apple Reminders
/// through `CalendarManager`, and that stays the way to see what other apps put
/// on your list. This is the other half: somewhere to write a checklist item
/// down without EventKit's write permission, a chosen list, or a round trip to
/// Reminders.app. The two are shown separately for that reason.
struct TodoItem: Codable, Identifiable, Defaults.Serializable, Hashable {
    var id: UUID = UUID()
    var title: String
    var isDone: Bool = false
    var createdAt: Date = Date()
    /// Set when the box is ticked, cleared when it is unticked. Used to sort
    /// the done pile most-recent-first and to drive "clear completed".
    var completedAt: Date?
    var dueDate: Date?
    /// 0 none, 1 low, 2 medium, 3 high. An Int rather than an enum so an older
    /// build decoding a newer value degrades to a number rather than failing
    /// the whole array.
    var priority: Int = 0

    init(
        id: UUID = UUID(),
        title: String,
        isDone: Bool = false,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        dueDate: Date? = nil,
        priority: Int = 0
    ) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.dueDate = dueDate
        self.priority = priority
    }

    /// True when the item has a due date that has passed and is not done.
    var isOverdue: Bool {
        guard !isDone, let dueDate else { return false }
        return dueDate < Date()
    }

    /// True when the due date falls today.
    var isDueToday: Bool {
        guard let dueDate else { return false }
        return Calendar.current.isDateInToday(dueDate)
    }
}

/// How the list is ordered. Stored, so the choice survives a restart.
enum TodoSortOrder: String, Codable, CaseIterable, Defaults.Serializable {
    case manual
    case dueDate
    case priority
    case created

    var label: String {
        switch self {
        case .manual: return String(localized: "Manual")
        case .dueDate: return String(localized: "Due date")
        case .priority: return String(localized: "Priority")
        case .created: return String(localized: "Date added")
        }
    }
}

extension Int {
    /// Colour for a `TodoItem.priority`.
    var todoPriorityColor: Color? {
        switch self {
        case 3: return .red
        case 2: return .orange
        case 1: return .yellow
        default: return nil
        }
    }

    var todoPriorityLabel: String {
        switch self {
        case 3: return String(localized: "High")
        case 2: return String(localized: "Medium")
        case 1: return String(localized: "Low")
        default: return String(localized: "None")
        }
    }
}
