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

import Combine
import Darwin
import Defaults
import Foundation

/// CPU, memory and network readouts. Category 8.
///
/// **Reference-counted, not launch-started.** A stats poller is the single most
/// expensive thing this app could add — it is by definition periodic work whose
/// only purpose is to be looked at — so it samples nothing unless a view is on
/// screen asking for it. Views call `acquire()` on appear and `release()` on
/// disappear; the timer is created on 0 -> 1 and torn down on 1 -> 0.
///
/// This is the `AudioTap` pattern, and for the same reason: an always-on tap
/// feeding a view that is usually closed was nearly all of the 0.95% -> 0.08%
/// idle CPU win recorded in CLAUDE.md.
@MainActor
final class SystemStatsManager: ObservableObject {
    static let shared = SystemStatsManager()

    struct Sample: Equatable {
        var cpuPercent: Double = 0
        var memoryUsedBytes: UInt64 = 0
        var memoryTotalBytes: UInt64 = 0
        var networkInBytesPerSecond: Double = 0
        var networkOutBytesPerSecond: Double = 0

        var memoryPercent: Double {
            guard memoryTotalBytes > 0 else { return 0 }
            return Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100
        }
    }

    @Published private(set) var current = Sample()

    private var consumerCount = 0
    private var timer: DispatchSourceTimer?
    private var gateCancellable: AnyCancellable?

    private var lastCPUTicks: (used: UInt64, total: UInt64)?
    private var lastNetwork: (inBytes: UInt64, outBytes: UInt64, at: Date)?

    private init() {
        current.memoryTotalBytes = ProcessInfo.processInfo.physicalMemory
        // Suspend while nobody can see the screen, like every other poller here.
        gateCancellable = SystemActivityGate.shared.$shouldSuspendBackgroundWork
            .receive(on: DispatchQueue.main)
            .sink { [weak self] suspended in
                guard let self else { return }
                if suspended { self.stopTimer() } else if self.consumerCount > 0 { self.startTimer() }
            }
    }

    // MARK: - Consumers

    func acquire() {
        consumerCount += 1
        guard consumerCount == 1, !SystemActivityGate.shared.shouldSuspendBackgroundWork else { return }

        // Prime the counters, then take the first real sample shortly after.
        //
        // CPU and network are both rates, computed by differencing two
        // snapshots — the first read after acquire has nothing to difference
        // against and returns nil, which rendered as a flat 0 while the machine
        // was busy. Seeding here and sampling again a moment later means the
        // first number a view shows is a measurement rather than a placeholder.
        _ = readCPUPercent()
        _ = readNetworkRates()
        sample()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.consumerCount > 0 else { return }
            self.sample()
        }
        startTimer()
    }

    func release() {
        consumerCount = max(0, consumerCount - 1)
        guard consumerCount == 0 else { return }
        stopTimer()
        // Deltas are meaningless across a gap; drop them so the next acquire
        // does not report a rate averaged over however long the view was shut.
        lastCPUTicks = nil
        lastNetwork = nil
    }

    // MARK: - Timer

    private func startTimer() {
        guard timer == nil else { return }
        let interval = max(1.0, Defaults[.statsRefreshSeconds])
        let t = DispatchSource.makeTimerSource(queue: .main)
        // Half a second of leeway: these are readouts a human glances at, and
        // coalescing them with other wakeups costs nothing anyone can perceive.
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Sampling

    private func sample() {
        var next = current
        if let cpu = readCPUPercent() { next.cpuPercent = cpu }
        if let used = readMemoryUsedBytes() { next.memoryUsedBytes = used }
        if let net = readNetworkRates() {
            next.networkInBytesPerSecond = net.inRate
            next.networkOutBytesPerSecond = net.outRate
        }
        if next != current { current = next }
    }

    /// Whole-machine CPU, from the difference between two tick snapshots.
    private func readCPUPercent() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle

        defer { lastCPUTicks = (used, total) }
        // The first sample after acquire has no predecessor to difference
        // against; reporting an absolute since-boot ratio there would show a
        // number that has nothing to do with now.
        guard let last = lastCPUTicks, total > last.total else { return nil }
        return Double(used - last.used) / Double(total - last.total) * 100
    }

    private func readMemoryUsedBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        // What Activity Monitor calls memory pressure: resident work that cannot
        // simply be dropped. Cached files are excluded deliberately — counting
        // them makes a healthy machine look full.
        return (UInt64(stats.active_count) + UInt64(stats.wire_count)
                + UInt64(stats.compressor_page_count)) * page
    }

    private func readNetworkRates() -> (inRate: Double, outRate: Double)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard ptr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let data = ptr.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            inBytes += UInt64(data.pointee.ifi_ibytes)
            outBytes += UInt64(data.pointee.ifi_obytes)
        }

        let now = Date()
        defer { lastNetwork = (inBytes, outBytes, now) }
        guard let last = lastNetwork else { return nil }
        let seconds = now.timeIntervalSince(last.at)
        guard seconds > 0 else { return nil }
        // Counters are cumulative and can wrap or reset when an interface goes
        // away; a negative delta means the baseline is gone, not that traffic
        // ran backwards.
        let dIn = inBytes >= last.inBytes ? Double(inBytes - last.inBytes) : 0
        let dOut = outBytes >= last.outBytes ? Double(outBytes - last.outBytes) : 0
        return (dIn / seconds, dOut / seconds)
    }
}
