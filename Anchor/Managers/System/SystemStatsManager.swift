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

import AnchorUtilities
import Combine
import Foundation

/// One shared sampler for native Stats and utility monitors. No hardware reads
/// occur here; the visible tab owns a lease and releases it on disappear/sleep.
@MainActor
final class SystemStatsManager: ObservableObject {
    static let shared = SystemStatsManager()
    typealias Sample = UtilitySystemStats.Reading
    @Published private(set) var current = Sample()
    @Published private(set) var isSampling = false
    private var consumerCount = 0
    private var backgroundCount = 0
    private var holdsLease = false
    private var subscriptions = Set<AnyCancellable>()

    private init() {
        UtilitySystemStats.shared.$reading.sink { [weak self] in self?.current = $0 }
            .store(in: &subscriptions)
        UtilitySystemStats.shared.$backgroundMonitoringEnabled.removeDuplicates()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() }.store(in: &subscriptions)
        SystemActivityGate.shared.$shouldSuspendBackgroundWork
            .removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }.store(in: &subscriptions)
    }
    func acquire(background: Bool = false) {
        if background { backgroundCount += 1 } else { consumerCount += 1 }
        sync()
    }
    func release(background: Bool = false) {
        if background { backgroundCount = max(0, backgroundCount - 1) }
        else { consumerCount = max(0, consumerCount - 1) }
        sync()
    }
    private func sync() {
        let wanted = (consumerCount > 0 || (backgroundCount > 0 && UtilitySystemStats.shared.backgroundMonitoringEnabled)) && !SystemActivityGate.shared.shouldSuspendBackgroundWork
        guard wanted != holdsLease else { return }
        holdsLease = wanted
        isSampling = wanted
        if wanted { UtilitySystemStats.shared.acquire() }
        else { UtilitySystemStats.shared.release() }
    }
}

extension UtilitySystemStats.Reading {
    var memoryPercent: Double {
        memoryTotalBytes > 0 ? Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100 : 0
    }
}
