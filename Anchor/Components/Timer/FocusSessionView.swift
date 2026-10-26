import AppKit
import SwiftUI

struct FocusSessionView: View {
    @ObservedObject private var focus = FocusSessionManager.shared
    @ObservedObject private var timer = TimerManager.shared
    @State private var intention = ""

    var body: some View {
        Group {
        VStack(alignment: .leading, spacing: 10) {
            if !focus.state.hasSession {
                TextField("What are you working on?", text: $intention)
                    .textFieldStyle(AnchorFieldStyle()).onSubmit { start() }
                HStack {
                    Label("\(focus.configuration.focusMinutes) minute focus", systemImage: "scope")
                        .font(.headline)
                    Spacer()
                    Button("Start focus", action: start).buttonStyle(AnchorButtonStyle(prominent: true))
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(focus.state.phase.title).font(.headline)
                        Text(focus.state.intention.isEmpty ? "One thing at a time" : focus.state.intention)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(focus.state.awaitingNext ? "Ready" : timer.formattedTimeRemaining)
                        .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                HStack {
                    if focus.state.awaitingNext {
                        Button("Start \(focus.state.phase.title.lowercased())") { focus.continueCycle() }
                            .buttonStyle(AnchorButtonStyle(prominent: true))
                    } else {
                        Button(timer.isPaused ? "Resume" : "Pause") {
                            timer.isPaused ? timer.resumeTimer() : timer.pauseTimer()
                        }.buttonStyle(AnchorButtonStyle())
                    }
                    if focus.state.phase != .focus { Button("Skip break") { focus.skipBreak() } }
                    Spacer()
                    Button("End session") { focus.stop() }.foregroundStyle(.secondary)
                }
            }
            HStack {
                let today = focus.completedToday()
                Text("Today: \(today.count) sessions · \(Int(today.reduce(0) { $0 + $1.duration } / 60)) min")
                Spacer()
                if focus.state.hasSession { Text("Round \(focus.state.completedRounds + (focus.state.phase == .focus ? 1 : 0))") }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(12)
        .onAppear { focus.restoreIfNeeded() }
            }
        .anchorTheme()
    }

    private func start() { focus.startFocus(intention: intention) }
}

