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

import Foundation
import IOKit
import IOKit.ps

/// Lightweight helper for querying macOS battery charging status and ETA.
final class MacBatteryManager {
    static let shared = MacBatteryManager()

    private init() {}

    struct BatteryStatus {
        let timeRemainingMinutes: Int?
        let isCharging: Bool
        let percentage: Int?
    }

    /// What the battery itself reports about its own condition.
    ///
    /// Read straight from the `AppleSmartBattery` IORegistry node. All of it
    /// needs no privileges — it is only the *control* side of battery
    /// management (charge limiting) that needs a privileged helper, and that is
    /// why the readout exists while the limit does not.
    struct BatteryHealth {
        /// Full charges' worth of use, as counted by the battery.
        let cycleCount: Int
        /// What it can hold now, in mAh.
        let nominalCapacity: Int
        /// What it could hold when new, in mAh.
        let designCapacity: Int
        /// Battery temperature in °C.
        let temperature: Double
        /// Terminal fault flagged by the battery controller.
        let permanentFailure: Bool

        /// Capacity remaining as a percentage of design, which is what
        /// System Information calls battery health.
        var healthPercent: Int? {
            guard designCapacity > 0 else { return nil }
            return Int((Double(nominalCapacity) / Double(designCapacity) * 100).rounded())
        }

        /// Apple's own wording. The cycle threshold is where Apple considers a
        /// notebook battery consumed.
        var condition: String {
            if permanentFailure { return "Service Recommended" }
            guard let health = healthPercent else { return "Unknown" }
            if health < 80 || cycleCount >= 1000 { return "Service Recommended" }
            return "Normal"
        }
    }

    /// Reads the battery's own condition registers.
    ///
    /// Returns nil on a Mac with no battery. Called on demand and on power
    /// source changes — never on a timer; none of these values move quickly.
    func currentHealth() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        func int(_ key: String) -> Int? {
            guard let value = IORegistryEntryCreateCFProperty(
                service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            else { return nil }
            return value.intValue
        }

        guard let design = int("DesignCapacity"), design > 0 else { return nil }

        // NominalChargeCapacity is what System Information uses. AppleRawMaxCapacity
        // is the pre-calibration figure and reads lower; falling back to it is
        // better than reporting nothing.
        let nominal = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? 0

        return BatteryHealth(
            cycleCount: int("CycleCount") ?? 0,
            nominalCapacity: nominal,
            designCapacity: design,
            // Reported in hundredths of a degree Celsius.
            temperature: Double(int("Temperature") ?? 0) / 100,
            permanentFailure: (int("PermanentFailureStatus") ?? 0) != 0
        )
    }

    func currentStatus() -> BatteryStatus {
        guard let sourcesInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourcesList = IOPSCopyPowerSourcesList(sourcesInfo)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryStatus(timeRemainingMinutes: nil, isCharging: false, percentage: nil)
        }

        for source in sourcesList {
            guard let description = IOPSGetPowerSourceDescription(sourcesInfo, source)?.takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else {
                continue
            }

            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let timeRemaining = description[kIOPSTimeToFullChargeKey] as? Int
            let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int
            let maxCapacity = description[kIOPSMaxCapacityKey] as? Int

            let percentage: Int?
            if let current = currentCapacity, let max = maxCapacity, max > 0 {
                percentage = (current * 100) / max
            } else {
                percentage = nil
            }

            return BatteryStatus(
                timeRemainingMinutes: timeRemaining,
                isCharging: isCharging,
                percentage: percentage
            )
        }

        return BatteryStatus(timeRemainingMinutes: nil, isCharging: false, percentage: nil)
    }

    func formattedTimeToFullCharge() -> String? {
        let status = currentStatus()
        guard status.isCharging, let minutes = status.timeRemainingMinutes, minutes > 0 else {
            return nil
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60

        if hours > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }
        return "\(remainingMinutes)m"
    }
}
