import AppKit
import Combine
import Foundation

@MainActor
final class FocusSessionManager: ObservableObject {
    static let shared = FocusSessionManager()

    struct CompletedSession: Identifiable, Codable {
        let id: UUID
        let endedAt: Date
        let duration: TimeInterval
        let intention: String
    }
    private struct Saved: Codable {
        var configuration: FocusCycleConfiguration
        var state: FocusCycleState
        var history: [CompletedSession]
    }

    @Published var configuration = FocusCycleConfiguration() { didSet { persist() } }
    @Published private(set) var state = FocusCycleState()
    @Published private(set) var history: [CompletedSession] = []
    private var restored = false
    private var sleepObserver: NSObjectProtocol?
    private let storageKey = "AnchorFocusCycle.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            configuration = saved.configuration; state = saved.state; history = saved.history
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.state.deadline != nil else { return }
                TimerManager.shared.pauseTimer()
            }
        }
    }

    func restoreIfNeeded() {
        guard !restored else { return }
        restored = true
        guard state.hasSession, !state.awaitingNext else { return }
        if state.deadline != nil && state.remaining(at: Date()) <= 0 {
            finishPhase(allowAutomaticContinuation: false)
        } else {
            attachTimer(remaining: state.remaining(at: Date()), paused: state.pausedRemaining != nil)
        }
    }

    func startFocus(intention: String = "") {
        // Cancel through the timer first so its interruption callback cannot erase the new state.
        if TimerManager.shared.activeSource == .focus { TimerManager.shared.forceStopTimer() }
        state = FocusCycleState()
        state.intention = intention.trimmingCharacters(in: .whitespacesAndNewlines)
        beginPhase()
    }

    func continueCycle() {
        guard state.awaitingNext else { return }
        beginPhase()
    }

    func skipBreak() {
        guard state.phase != .focus else { return }
        let rounds = state.completedRounds, intention = state.intention
        TimerManager.shared.forceStopTimer()
        state = FocusCycleState(); state.completedRounds = rounds; state.intention = intention
        beginPhase()
    }

    func stop() {
        if TimerManager.shared.activeSource == .focus { TimerManager.shared.forceStopTimer() }
        state = FocusCycleState()
        persist()
    }

    func completedToday(at date: Date = Date()) -> [CompletedSession] {
        history.filter { Calendar.current.isDate($0.endedAt, inSameDayAs: date) }
    }

    private func beginPhase() {
        state.awaitingNext = false
        state.phaseID = UUID()
        state.phaseDuration = configuration.duration(for: state.phase)
        state.deadline = Date().addingTimeInterval(state.phaseDuration)
        state.pausedRemaining = nil
        attachTimer(remaining: state.phaseDuration, paused: false)
        persist()
    }

    private func attachTimer(remaining: TimeInterval, paused: Bool) {
        let token = state.phaseID
        TimerManager.shared.startFocusTimer(duration: remaining, name: state.phase.title,
            onFinish: { [weak self] in
                guard let self, self.state.phaseID == token else { return }
                let timely = self.state.deadline.map { Date().timeIntervalSince($0) < 3 } ?? false
                self.finishPhase(allowAutomaticContinuation: timely)
            }, onInterrupt: { [weak self] in
                guard let self, self.state.phaseID == token else { return }
                self.state = FocusCycleState(); self.persist()
            }, onPause: { [weak self] paused, remaining in
                guard let self, self.state.phaseID == token else { return }
                self.state.pausedRemaining = paused ? max(0, remaining) : nil
                self.state.deadline = paused ? nil : Date().addingTimeInterval(remaining)
                self.persist()
            })
        if paused { TimerManager.shared.pauseTimer() }
    }

    private func finishPhase(allowAutomaticContinuation: Bool) {
        let finished = CompletedSession(id: state.phaseID, endedAt: state.deadline ?? Date(),
                                       duration: state.phaseDuration, intention: state.intention)
        if state.completePhase(configuration: configuration), !history.contains(where: { $0.id == finished.id }) {
            history.insert(finished, at: 0)
            history = Array(history.prefix(1_000))
        }
        persist()
        NSSound(named: .init("Glass"))?.play()
        if configuration.automaticallyContinue && allowAutomaticContinuation { beginPhase() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Saved(configuration: configuration, state: state, history: history)) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
