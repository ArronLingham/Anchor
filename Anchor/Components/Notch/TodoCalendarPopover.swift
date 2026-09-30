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

import SwiftUI

/// A native graphical calendar popover for selecting a custom due date for a to-do item.
struct TodoCalendarPopover: View {
    @Binding var dueDate: Date?
    var itemTitle: String?
    var onDismiss: () -> Void

    @State private var selectedDate: Date
    @State private var hasSelectedDate: Bool

    init(dueDate: Binding<Date?>, itemTitle: String? = nil, onDismiss: @escaping () -> Void) {
        self._dueDate = dueDate
        self.itemTitle = itemTitle
        self.onDismiss = onDismiss
        if let initial = dueDate.wrappedValue {
            self._selectedDate = State(initialValue: initial)
            self._hasSelectedDate = State(initialValue: true)
        } else {
            self._selectedDate = State(initialValue: Date())
            self._hasSelectedDate = State(initialValue: false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Due Date")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)

                    if let title = itemTitle, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                Spacer()

                if hasSelectedDate || dueDate != nil {
                    Button {
                        dueDate = nil
                        hasSelectedDate = false
                        onDismiss()
                    } label: {
                        Text("Clear")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .help("Remove due date")
                }
            }

            // Quick Presets
            HStack(spacing: 6) {
                let today = Calendar.current.date(
                    bySettingHour: 23, minute: 59, second: 59, of: Date()) ?? Date()
                presetButton(title: "Today", date: today)

                let tomorrow = Calendar.current.date(
                    byAdding: .day, value: 1, to: today) ?? Date()
                presetButton(title: "Tomorrow", date: tomorrow)

                let nextWeek = Calendar.current.date(
                    byAdding: .day, value: 7, to: today) ?? Date()
                presetButton(title: "Next Week", date: nextWeek)
            }

            Divider()
                .background(.white.opacity(0.15))

            // Interactive Graphical Calendar Picker
            DatePicker(
                "Select Date",
                selection: Binding(
                    get: { selectedDate },
                    set: { newDate in
                        // Preserve end-of-day time so it is valid for the chosen day
                        let endOfDay = Calendar.current.date(
                            bySettingHour: 23, minute: 59, second: 59, of: newDate) ?? newDate
                        selectedDate = endOfDay
                        hasSelectedDate = true
                        dueDate = endOfDay
                    }
                ),
                displayedComponents: [.date]
            )
            .datePickerStyle(.graphical)
            .labelsHidden()

            Divider()
                .background(.white.opacity(0.15))

            // Footer with formatted selection and Done button
            HStack {
                if hasSelectedDate {
                    Text(formattedDisplayDate(selectedDate))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                } else {
                    Text("No due date")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer()

                Button("Done") {
                    // The calendar initially highlights today even with no
                    // stored date. Done must commit that visible selection too.
                    dueDate = hasSelectedDate ? selectedDate : Calendar.current.date(
                        bySettingHour: 23, minute: 59, second: 59, of: selectedDate) ?? selectedDate
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 270)
        .preferredColorScheme(.dark)
    }

    private func presetButton(title: String, date: Date) -> some View {
        let isSelected = hasSelectedDate && Calendar.current.isDate(selectedDate, inSameDayAs: date)
        return Button {
            selectedDate = date
            hasSelectedDate = true
            dueDate = date
        } label: {
            Text(title)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08))
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    private func formattedDisplayDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Today"
        } else if cal.isDateInTomorrow(date) {
            return "Tomorrow"
        } else {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
    }
}
