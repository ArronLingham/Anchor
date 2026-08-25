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

import AppKit
import Combine
import Defaults
import Foundation

/// The 20-20-20 rule: every twenty minutes, look twenty feet away for twenty
/// seconds. Category 20.
///
/// Costs one timer, and only while enabled. The timer is scheduled for the next
/// due moment rather than ticking — a countdown that nothing is displaying does
/// not need to exist, and the notch reads `secondsRemaining` off a date when it
/// draws rather than being pushed a value every second.
///
/// Screen-off time is not work time. The gate suspends the schedule on display
/// sleep, lock and Low Power Mode, and the interval restarts when you come back,
/// because a reminder fired the instant you sit down is one you dismiss without
/// looking, and the twenty minutes it measured were spent away from the screen.
@MainActor
final class EyeBreakManager: ObservableObject {
    static let shared = EyeBreakManager()

    enum Phase: Equatable {
        case idle
        /// Counting down to the next break.
        case working(until: Date)
        /// The break itself is running.
        case resting(until: Date)
    }

    @Published private(set) var phase: Phase = .idle

    /// Breaks completed today, for the compliance readout.
    @Published private(set) var completedToday = 0
    @Published private(set) var skippedToday = 0

    private var timer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()
    private var dayStamp = Calendar.current.startOfDay(for: Date())

    var isActive: Bool { phase != .idle }

    /// True only while the break itself is running, which is the window the
    /// notch shows a prompt for.
    var isResting: Bool { if case .resting = phase { return true }; return false }

    /// Seconds left in the current phase, derived on read. Nothing publishes per
    /// second; a view that wants a live countdown drives its own TimelineView.
    var secondsRemaining: TimeInterval {
        switch phase {
        case .idle: return 0
        case .working(let until), .resting(let until):
            return max(0, until.timeIntervalSinceNow)
        }
    }

    private init() {
        // Deferred: per CLAUDE.md nothing may block in a manager's init, and this
        // subscribes to a published gate that AppDelegate builds around us.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observeSettings()
            self.observeActivityGate()
            self.syncToSettings()
        }
    }

    // MARK: - Wiring

    private func observeSettings() {
        Defaults.publisher(.eyeBreakEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncToSettings() }
            .store(in: &cancellables)

        Defaults.publisher(.eyeBreakWorkMinutes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartIfWorking() }
            .store(in: &cancellables)
    }

    private func observeActivityGate() {
        SystemActivityGate.shared.$shouldSuspendBackgroundWork
            .receive(on: DispatchQueue.main)
            .sink { [weak self] suspended in
                guard let self, Defaults[.eyeBreakEnabled] else { return }
                if suspended {
                    self.cancelTimer()
                    self.phase = .idle
                } else {
                    // Fresh interval on return: the time spent away was not
                    // screen time, and a reminder that fires immediately is one
                    // that gets dismissed unread.
                    self.beginWorking()
                }
            }
            .store(in: &cancellables)
    }

    private func syncToSettings() {
        if Defaults[.eyeBreakEnabled], !SystemActivityGate.shared.shouldSuspendBackgroundWork {
            beginWorking()
        } else {
            cancelTimer()
            phase = .idle
        }
    }

    private func restartIfWorking() {
        if case .working = phase { beginWorking() }
    }

    // MARK: - Phases

    private func beginWorking() {
        rolloverDayIfNeeded()
        let minutes = max(1, Defaults[.eyeBreakWorkMinutes])
        let until = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        phase = .working(until: until)
        schedule(at: until) { [weak self] in self?.beginResting() }
    }

    private func beginResting() {
        let seconds = max(5, Defaults[.eyeBreakRestSeconds])
        let until = Date().addingTimeInterval(TimeInterval(seconds))
        phase = .resting(until: until)
        AnchorViewCoordinator.shared.toggleExpandingView(status: true, type: .eyeBreak)
        schedule(at: until) { [weak self] in
            guard let self else { return }
            self.completedToday += 1
            self.beginWorking()
        }
    }

    /// Dismiss the break early. Counted, so the compliance figure means something.
    func skipRest() {
        guard case .resting = phase else { return }
        skippedToday += 1
        beginWorking()
    }

    private func rolloverDayIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today != dayStamp else { return }
        dayStamp = today
        completedToday = 0
        skippedToday = 0
    }

    // MARK: - Timer

    /// One shot at a wall-clock moment. Leeway lets the system coalesce it with
    /// other wakeups — nothing here needs to be accurate to the second.
    private func schedule(at date: Date, _ body: @escaping () -> Void) {
        cancelTimer()
        let interval = max(0, date.timeIntervalSinceNow)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, leeway: .seconds(5))
        t.setEventHandler(handler: body)
        t.resume()
        timer = t
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
