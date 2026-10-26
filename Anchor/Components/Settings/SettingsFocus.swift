import SwiftUI

struct FocusSettingsSection: View {
    @ObservedObject private var focus = FocusSessionManager.shared

    private func highlightID(_ title: String) -> String { SettingsTab.timer.highlightID(for: title) }

    var body: some View {
        Section {
            Stepper("Focus: \(focus.configuration.focusMinutes) minutes", value: $focus.configuration.focusMinutes, in: 1...180)
                .settingsHighlight(id: highlightID("Focus duration"))
            Stepper("Short break: \(focus.configuration.shortBreakMinutes) minutes", value: $focus.configuration.shortBreakMinutes, in: 1...60)
                .settingsHighlight(id: highlightID("Short break duration"))
            Stepper("Long break: \(focus.configuration.longBreakMinutes) minutes", value: $focus.configuration.longBreakMinutes, in: 1...120)
                .settingsHighlight(id: highlightID("Long break duration"))
            Stepper("Long break every \(focus.configuration.roundsBeforeLongBreak) rounds", value: $focus.configuration.roundsBeforeLongBreak, in: 1...12)
                .settingsHighlight(id: highlightID("Focus rounds"))
            Toggle("Automatically start the next phase", isOn: $focus.configuration.automaticallyContinue)
                .settingsHighlight(id: highlightID("Automatic focus phases"))
            Text("Start from the Timer tab or dashboard. Sessions pause when the Mac sleeps and resume when you choose. Completed focus sessions are saved locally.")
                .font(.caption).foregroundStyle(.secondary)
            if !focus.history.isEmpty {
                ForEach(focus.history.prefix(5)) { session in
                    HStack {
                        Text(session.intention.isEmpty ? "Focus session" : session.intention).lineLimit(1)
                        Spacer()
                        Text("\(Int(session.duration / 60)) min").foregroundStyle(.secondary)
                        Text(session.endedAt, style: .date).foregroundStyle(.secondary)
                    }.font(.caption)
                }
            }
        } header: { Text("Focus sessions") }
    }
}
