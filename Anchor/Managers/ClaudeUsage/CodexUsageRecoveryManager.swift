import AppKit
import AnchorUtilities
import Combine
import Defaults
import Foundation

/// Owns the native settings/phone bridge. Detection itself uses file events and
/// a reset deadline, independently of whether the usage card is visible.
@MainActor
final class CodexUsageRecoveryManager {
    static let shared = CodexUsageRecoveryManager()
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var phoneTimer: Timer?
    private var phoneReset: Date?
    private var phoneGeneration = UUID()
    private var phoneAttempts = 0
    private var wakeObserver: NSObjectProtocol?
    func start() {
        guard !started else { return }
        started = true
        UtilityCodexRecovery.shared.$resetDate.removeDuplicates().sink { [weak self] date in
            guard let self else { return }
            self.phoneTimer?.invalidate(); self.phoneTimer = nil
            self.phoneReset = date; self.phoneGeneration = UUID(); self.phoneAttempts = 0
            if let date { self.schedulePhone(reset: date) }
        }.store(in: &subscriptions)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    if let self, let date = self.phoneReset { self.schedulePhone(reset: date) }
                }
            }
        Defaults.publisher(.codexUsageWatchEnabled).sink { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }.store(in: &subscriptions)
        Defaults.publisher(.codexUsageAutoResume).sink { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }.store(in: &subscriptions)
        sync()
    }
    private func sync() {
        if !Defaults[.codexUsageWatchEnabled] {
            phoneTimer?.invalidate(); phoneTimer = nil; phoneReset = nil; phoneGeneration = UUID()
        }
        UtilityCodexRecovery.shared.configure(enabled: Defaults[.codexUsageWatchEnabled],
                                             autoResume: Defaults[.codexUsageAutoResume])
    }
    private func schedulePhone(reset: Date) {
        phoneTimer?.invalidate(); phoneTimer = nil
        guard Defaults[.codexUsageWatchEnabled], phoneReset == reset,
              Defaults[.codexPhoneLastScheduled] != reset.timeIntervalSince1970 else { return }
        // ntfy rejects delivery more than three days ahead. Use a one-shot
        // deadline to enter that window, and recheck it on wake/relaunch.
        let wait = reset.timeIntervalSinceNow - (3 * 24 * 3600 - 60)
        if wait > 0 {
            phoneTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.schedulePhone(reset: reset) }
            }
            return
        }
        let token = phoneGeneration
        PhonePush.send(title: "Codex usage reset", body: "Your Codex usage window has reset.",
                       deliverAt: reset) { [weak self] sent in
            Task { @MainActor in
                guard let self, self.phoneGeneration == token, self.phoneReset == reset else { return }
                if sent { Defaults[.codexPhoneLastScheduled] = reset.timeIntervalSince1970 }
                else if self.phoneAttempts < 3 {
                    self.phoneAttempts += 1
                    self.phoneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                        Task { @MainActor in self?.schedulePhone(reset: reset) }
                    }
                }
            }
        }
    }

}
