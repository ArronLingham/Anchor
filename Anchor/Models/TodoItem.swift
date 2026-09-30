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
/// Stored locally first. Optional Reminders sync provides phone access without
/// making local task capture depend on account access or network availability.
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

    enum CodingKeys: String, CodingKey {
        case id, title, isDone, createdAt, completedAt, dueDate, priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: container, debugDescription: "Empty task title")
        }
        isDone = try container.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        // Old Defaults used reference-date numbers; Gemini's disk writer used ISO-8601.
        // Accept both without silently throwing away dates that cannot be decoded.
        func date(_ key: CodingKeys) throws -> Date? {
            guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
            if let number = try? container.decode(Double.self, forKey: key), number.isFinite {
                return Date(timeIntervalSinceReferenceDate: number)
            }
            let string = try container.decode(String.self, forKey: key)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = formatter.date(from: string) { return value }
            formatter.formatOptions = [.withInternetDateTime]
            guard let value = formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Invalid date")
            }
            return value
        }
        createdAt = try date(.createdAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        completedAt = try date(.completedAt)
        dueDate = try date(.dueDate)
        priority = max(0, min(3, try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(isDone, forKey: .isDone)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(dueDate, forKey: .dueDate)
        try container.encode(priority, forKey: .priority)
    }

    /// Safely decodes a list of TodoItems even if individual items or properties are malformed.
    static func safeDecodeList(from data: Data) -> [TodoItem] {
        let decoder = JSONDecoder()
        if let items = try? decoder.decode([TodoItem].self, from: data) {
            return items
        }
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        var recovered: [TodoItem] = []
        for value in rawArray {
            guard let dict = value as? [String: Any] else { continue }
            if let itemData = try? JSONSerialization.data(withJSONObject: dict),
               let item = try? decoder.decode(TodoItem.self, from: itemData) {
                recovered.append(item)
            }
        }
        return recovered
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

    func directionLabel(inverted: Bool) -> String {
        switch self {
        case .manual:
            return String(localized: "Default")
        case .dueDate:
            return inverted ? String(localized: "Latest first") : String(localized: "Earliest first")
        case .priority:
            return inverted ? String(localized: "Lowest first") : String(localized: "Highest first")
        case .created:
            return inverted ? String(localized: "Oldest first") : String(localized: "Newest first")
        }
    }

    /// Compares two items under a single criterion.
    static func compareCriterion(
        _ lhs: TodoItem,
        _ rhs: TodoItem,
        criterion: TodoSortOrder,
        inverted: Bool
    ) -> ComparisonResult {
        switch criterion {
        case .manual:
            return .orderedSame

        case .priority:
            if lhs.priority == rhs.priority {
                return .orderedSame
            }
            if inverted {
                return lhs.priority < rhs.priority ? .orderedAscending : .orderedDescending
            } else {
                return lhs.priority > rhs.priority ? .orderedAscending : .orderedDescending
            }

        case .dueDate:
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?):
                if l == r {
                    return .orderedSame
                }
                if inverted {
                    return l > r ? .orderedAscending : .orderedDescending
                } else {
                    return l < r ? .orderedAscending : .orderedDescending
                }
            case (_?, nil):
                return .orderedAscending
            case (nil, _?):
                return .orderedDescending
            case (nil, nil):
                return .orderedSame
            }

        case .created:
            if lhs.createdAt == rhs.createdAt {
                return .orderedSame
            }
            if inverted {
                return lhs.createdAt < rhs.createdAt ? .orderedAscending : .orderedDescending
            } else {
                return lhs.createdAt > rhs.createdAt ? .orderedAscending : .orderedDescending
            }
        }
    }

    /// Sorts a collection of TodoItems using primary and secondary criteria with optional inversions.
    static func sort(
        _ items: [TodoItem],
        order: TodoSortOrder,
        inverted: Bool = false,
        secondary: TodoSecondarySortOrder = .none,
        secondaryInverted: Bool = false
    ) -> [TodoItem] {
        guard order != .manual else { return items }

        let secondaryCriterion: TodoSortOrder?
        switch secondary {
        case .none: secondaryCriterion = nil
        case .dueDate: secondaryCriterion = .dueDate
        case .priority: secondaryCriterion = .priority
        case .created: secondaryCriterion = .created
        }

        return items.sorted { lhs, rhs in
            // 1. Primary sort
            let primaryResult = compareCriterion(lhs, rhs, criterion: order, inverted: inverted)
            if primaryResult != .orderedSame {
                return primaryResult == .orderedAscending
            }

            // 2. Secondary sort (if active and not identical to primary)
            if let secondaryCriterion, secondaryCriterion != order {
                let secondaryResult = compareCriterion(lhs, rhs, criterion: secondaryCriterion, inverted: secondaryInverted)
                if secondaryResult != .orderedSame {
                    return secondaryResult == .orderedAscending
                }
            }

            // 3. Fallback tie-breaker: oldest created item first
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }

            // 4. Stable tie-breaker
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

/// Secondary sort options for breaking ties when items share the same primary value.
enum TodoSecondarySortOrder: String, Codable, CaseIterable, Defaults.Serializable {
    case none
    case dueDate
    case priority
    case created

    var label: String {
        switch self {
        case .none: return String(localized: "None")
        case .dueDate: return String(localized: "Due date")
        case .priority: return String(localized: "Priority")
        case .created: return String(localized: "Date added")
        }
    }

    func directionLabel(inverted: Bool) -> String {
        switch self {
        case .none:
            return String(localized: "Default")
        case .dueDate:
            return inverted ? String(localized: "Latest first") : String(localized: "Earliest first")
        case .priority:
            return inverted ? String(localized: "Lowest first") : String(localized: "Highest first")
        case .created:
            return inverted ? String(localized: "Oldest first") : String(localized: "Newest first")
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
