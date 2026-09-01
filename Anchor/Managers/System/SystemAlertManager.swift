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
import SwiftUI
import Defaults
import Foundation

// MARK: - Pure decision

/// A threshold with hysteresis and a re-arm rule.
///
/// ## Why this is not just `value < threshold`
///
/// A battery sitting at exactly 20% crosses back and forth on every sample, and
/// a plain comparison fires an alert each time. Three things prevent that, and
/// all three are why this type exists rather than an `if`:
///
/// 1. **Hysteresis.** Once fired, the alert only clears when the value recovers
///    past the threshold *plus a margin*. Coming back to 20.1% is not recovery.
/// 2. **Latching.** While an alert is active it does not re-fire, however many
///    samples arrive.
/// 3. **Re-arming.** After clearing, a minimum interval must pass before the
///    same alert can fire again, so a value oscillating slowly across the
///    margin still cannot produce a stream of notifications.
///
/// Pure, because reproducing a flapping battery on real hardware means draining
/// one, and the bug it guards against only appears at the boundary.
struct AlertThreshold {
    /// The level at which the alert fires.
    var threshold: Double
    /// How far past the threshold the value must recover before the alert
    /// clears. Zero would reintroduce flapping.
    var recoveryMargin: Double
    /// Minimum seconds between one alert clearing and the next firing.
    var reArmSeconds: Double
    /// True when the alert fires on values *above* the threshold (CPU, disk
    /// used) rather than below it (battery remaining).
    var firesAbove: Bool

    struct State {
        var value: Double
        /// Whether this alert is currently active.
        var isActive: Bool
        /// Seconds since this alert last cleared. Infinity if it never has.
        var sinceLastCleared: Double
    }

    enum Outcome: Equatable {
        /// Fire now.
        case fire
        /// Clear an active alert — the value has recovered past the margin.
        case clear
        /// Do nothing.
        case hold
    }

    func evaluate(_ state: State) -> Outcome {
        let breached = firesAbove ? state.value >= threshold : state.value <= threshold

        if state.isActive {
            // Recovery needs the margin, not merely crossing back.
            let recovered = firesAbove
                ? state.value < threshold - recoveryMargin
                : state.value > threshold + recoveryMargin
            return recovered ? .clear : .hold
        }

        guard breached else { return .hold }
        // Re-arm interval since the last time this cleared.
        guard state.sinceLastCleared >= reArmSeconds else { return .hold }
        return .fire
    }
}

/// Requires a condition to persist before it counts.
///
/// CPU spikes to 100% constantly and briefly — a build, a page load, opening an
/// app. An alert on the instantaneous value is noise. This holds the condition
/// for a duration before agreeing it is real.
struct SustainedCondition {
    /// How long the condition must hold.
    var requiredSeconds: Double

    /// Whether the condition, held since `heldSince`, now counts.
    ///
    /// `heldSince` is nil when the condition is not currently true.
    func isSustained(heldSince: Date?, now: Date) -> Bool {
        guard let heldSince else { return false }
        return now.timeIntervalSince(heldSince) >= requiredSeconds
    }
}

// MARK: - Manager

/// Warns about low battery, a full disk and sustained high CPU.
///
/// ## Cost
///
/// Battery is event-driven — it subscribes to `BatteryActivityManager`, which
/// already owns an `IOPSNotificationCreateRunLoopSource`, so no new source is
/// created. Disk and CPU share one timer that only runs while at least one of
/// those two alerts is enabled, and it ticks at 60 s: a disk does not fill
/// suddenly, and the sustained-CPU rule needs minutes to trigger anyway.
@MainActor
final class SystemAlertManager: ObservableObject {
    static let shared = SystemAlertManager()

    enum Alert: String, CaseIterable {
        case batteryLow, diskFull, cpuHigh

        var title: String {
            switch self {
            case .batteryLow: return "Battery low"
            case .diskFull:   return "Disk almost full"
            case .cpuHigh:    return "CPU has been busy"
            }
        }
        var icon: String {
            switch self {
            case .batteryLow: return "battery.25"
            case .diskFull:   return "internaldrive"
            case .cpuHigh:    return "cpu"
            }
        }
    }

    /// What the closed-notch banner is currently showing, if anything.
    ///
    /// Published rather than pushed through `NotificationCenter`: the first
    /// version posted a notification no part of the app observed, so every
    /// alert this manager correctly detected went nowhere at all.
    @Published private(set) var visibleAlert: VisibleAlert?

    struct VisibleAlert: Equatable {
        let title: String
        let detail: String
        let icon: String
        let kind: Alert

        var tint: Color {
            switch kind {
            case .batteryLow: return .red
            case .diskFull:   return .orange
            case .cpuHigh:    return .yellow
            }
        }
    }

    /// Hides the banner. The alert stays *latched* — dismissing the banner is
    /// not recovery, so it must not re-fire a moment later.
    func dismissVisibleAlert() {
        visibleAlert = nil
        bannerTask?.cancel()
        bannerTask = nil
    }

    private var bannerTask: Task<Void, Never>?
    private var active: Set<Alert> = []
    private var lastCleared: [Alert: Date] = [:]
    private var cpuHighSince: Date?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private let sustainedCPU = SustainedCondition(requiredSeconds: 300)
    private var batteryObserverID: Int?
    private var lastBatteryCharging = false
    private var lastBatteryLevel: Double = 100

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        for key in [Defaults.Keys.enableBatteryAlert, Defaults.Keys.enableDiskAlert,
                    Defaults.Keys.enableCPUAlert] {
            Defaults.publisher(key)
                .sink { [weak self] _ in Task { @MainActor in self?.syncTimer() } }
                .store(in: &cancellables)
        }
        SystemActivityGate.shared.$shouldSuspendBackgroundWork
            .sink { [weak self] _ in Task { @MainActor in self?.syncTimer() } }
            .store(in: &cancellables)

        syncTimer()
        observeBattery()
    }

    /// Subscribes to `BatteryActivityManager`, which already owns an
    /// `IOPSNotificationCreateRunLoopSource`. No new source is created and
    /// there is no battery timer — the OS signals when the level actually
    /// moves, which on a plugged-in machine is never.
    private func observeBattery() {
        let manager = BatteryActivityManager.shared
        batteryObserverID = manager.addObserver { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .batteryLevelChanged(let level):
                    self.lastBatteryLevel = Double(level)
                    self.evaluateBattery()
                case .isChargingChanged(let charging):
                    self.lastBatteryCharging = charging
                    // Plugging in must clear an active low-battery alert
                    // straight away rather than waiting for the level to climb
                    // past the recovery margin, which on a slow charger is
                    // several minutes of a stale warning. `evaluateBattery`
                    // substitutes 100 for the value while charging, so the
                    // recorded level is left alone and stays correct for when
                    // the cable comes out again.
                    self.evaluateBattery()
                case .powerSourceChanged(let pluggedIn):
                    self.lastBatteryCharging = pluggedIn
                default:
                    break
                }
            }
        }
        let info = manager.initializeBatteryInfo()
        lastBatteryCharging = info.isCharging
        lastBatteryLevel = Double(info.currentCapacity)
    }

    private func syncTimer() {
        // Parked while the display sleeps, the screen is locked or Low Power
        // Mode is on — the timer is torn down rather than left firing into a
        // guard, per the project rule that pollers park.
        let wantsTimer = (Defaults[.enableDiskAlert] || Defaults[.enableCPUAlert])
            && !SystemActivityGate.shared.shouldSuspendBackgroundWork
        if wantsTimer, timer == nil {
            // 60 s with generous leeway so the system can coalesce it with
            // other wakeups — nothing here is time-critical.
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            t.tolerance = 15
            RunLoop.main.add(t, forMode: .common)
            timer = t
            sample()
        } else if !wantsTimer {
            timer?.invalidate()
            timer = nil
            cpuHighSince = nil
        }
    }

    private func sample() {
        // Belt and braces: `syncTimer` tears the timer down when the gate
        // closes, but a fire already scheduled can still land afterwards.
        guard !SystemActivityGate.shared.shouldSuspendBackgroundWork else { return }
        if Defaults[.enableDiskAlert] { evaluateDisk() }
        if Defaults[.enableCPUAlert] { evaluateCPU() }
    }

    // MARK: Individual alerts

    private func evaluateDisk() {
        guard let usedPercent = diskUsedPercent() else { return }
        let rule = AlertThreshold(
            threshold: Double(Defaults[.diskAlertPercent]),
            recoveryMargin: 3, reArmSeconds: 3600, firesAbove: true)
        apply(rule, value: usedPercent, to: .diskFull,
              detail: String(format: "%.0f%% of the startup disk is used", usedPercent))
    }

    private func evaluateCPU() {
        let load = currentCPUPercent()
        let threshold = Double(Defaults[.cpuAlertPercent])

        if load >= threshold {
            if cpuHighSince == nil { cpuHighSince = Date() }
        } else {
            cpuHighSince = nil
        }

        // The sustained rule gates the threshold rule: a spike never reaches
        // `apply` at all, so the hysteresis state is not disturbed by noise.
        let sustained = sustainedCPU.isSustained(heldSince: cpuHighSince, now: Date())
        let rule = AlertThreshold(
            threshold: threshold, recoveryMargin: 10, reArmSeconds: 1800, firesAbove: true)
        apply(rule, value: sustained ? load : 0, to: .cpuHigh,
              detail: String(format: "%.0f%% for over five minutes", load))
    }

    /// Called from the battery observer rather than a timer.
    /// Re-runs the battery rule against the last level and charging state.
    func evaluateBattery() {
        guard Defaults[.enableBatteryAlert] else { return }
        let percent = lastBatteryLevel
        // Charging is not a low-battery situation whatever the level. The
        // substitution happens here rather than at the call site so
        // `lastBatteryLevel` keeps the real reading.
        let value = lastBatteryCharging ? 100 : percent
        let rule = AlertThreshold(
            threshold: Double(Defaults[.batteryAlertPercent]),
            recoveryMargin: 5, reArmSeconds: 900, firesAbove: false)
        apply(rule, value: value, to: .batteryLow,
              detail: String(format: "%.0f%% remaining", percent))
    }

    private func apply(_ rule: AlertThreshold, value: Double, to alert: Alert, detail: String) {
        let state = AlertThreshold.State(
            value: value,
            isActive: active.contains(alert),
            sinceLastCleared: lastCleared[alert].map { Date().timeIntervalSince($0) } ?? .infinity)

        switch rule.evaluate(state) {
        case .fire:
            active.insert(alert)
            post(alert, detail: detail)
        case .clear:
            active.remove(alert)
            lastCleared[alert] = Date()
            // If this alert's banner is still on screen when the condition
            // recovers, take it down. In practice the 12-second auto-hide has
            // usually beaten recovery here, but a warning that outlives the
            // thing it warns about is wrong however briefly.
            if visibleAlert?.kind == alert { dismissVisibleAlert() }
        case .hold:
            break
        }
    }

    private func post(_ alert: Alert, detail: String) {
        visibleAlert = VisibleAlert(
            title: alert.title, detail: detail, icon: alert.icon, kind: alert)
        NSLog("SystemAlert: \(alert.rawValue) — \(detail)")

        // Auto-hide after 12 seconds. The alert itself stays latched, so the
        // banner going away is not the same as the condition clearing — it will
        // not reappear until the value recovers and the re-arm interval passes.
        bannerTask?.cancel()
        bannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            guard self?.visibleAlert?.kind == alert else { return }
            self?.visibleAlert = nil
        }
    }

    // MARK: Readings

    private func diskUsedPercent() -> Double? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return (1 - Double(available) / Double(total)) * 100
    }

    /// System-wide CPU use, from host ticks.
    private var previousTicks: (used: UInt64, total: UInt64)?

    private func currentCPUPercent() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle

        defer { previousTicks = (used, total) }
        // Ticks are cumulative since boot, so the first reading has no delta to
        // compare against and would report the machine's lifetime average.
        guard let previous = previousTicks else { return 0 }
        let deltaTotal = total &- previous.total
        guard deltaTotal > 0 else { return 0 }
        return Double(used &- previous.used) / Double(deltaTotal) * 100
    }
}
