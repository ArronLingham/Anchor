import Combine
import Foundation

/// A visible Anchor Stats tab leases the same hardware sampler as utility panels.
/// The lease is independent of optional utility feature gates and is released on close.
@MainActor
public final class UtilitySystemStats: ObservableObject {
    public static let shared = UtilitySystemStats()
    public struct Reading: Equatable {
        public var cpuPercent: Double?
        public var gpuPercent: Double?
        public var cpuTemperature: Double?
        public var gpuTemperature: Double?
        public var batteryTemperature: Double?
        public var batteryPercent: Int?
        public var batteryWatts: Double?
        public var charging = false
        public var memoryUsedBytes: UInt64 = 0
        public var memoryTotalBytes: UInt64 = 0
        public var swapUsedBytes: UInt64 = 0
        public var memoryPressure = "Unknown"
        public var networkInBytesPerSecond: Double?
        public var networkOutBytesPerSecond: Double?
        public var networkInTotalBytes: UInt64 = 0
        public var networkOutTotalBytes: UInt64 = 0
        public init() {}
    }
    @Published public private(set) var reading = Reading()
    @Published public private(set) var backgroundMonitoringEnabled = UtilityPreferences.standard.bool(forKey: DefaultsKey.monitorBackgroundSampling)
    private var preferences: AnyCancellable?
    public func setBackgroundMonitoringEnabled(_ enabled: Bool) {
        UtilityPreferences.standard.set(enabled, forKey: DefaultsKey.monitorBackgroundSampling)
        backgroundMonitoringEnabled = enabled
        SystemMonitor.shared.planDidChange()
    }
    private let id = UUID()
    private var observing: AnyCancellable?
    private var clients = 0

    private init() {
        preferences = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UtilityPreferences.standard)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.backgroundMonitoringEnabled = UtilityPreferences.standard.bool(forKey: DefaultsKey.monitorBackgroundSampling)
            }
    }
    public func acquire() {
        clients += 1
        guard clients == 1 else { return }
        // No retained old rates while the next baseline is established.
        reading = Reading()
        observing = SystemMonitor.shared.$snapshot.dropFirst().sink { [weak self] s in
            MainActor.assumeIsolated {
                let pressure: String
                switch s.memoryPressure {
                case .normal: pressure = "Normal"
                case .warning: pressure = "Elevated"
                case .critical: pressure = "Critical"
                case .unknown: pressure = "Unknown"
                }
                var r = Reading()
                r.cpuPercent = s.cpuUsage.map { $0 * 100 }
                r.gpuPercent = s.gpuUsage.map { $0 * 100 }
                r.cpuTemperature = s.cpuTemperature
                r.gpuTemperature = s.gpuTemperature
                r.batteryTemperature = s.batteryTemperature
                r.batteryPercent = s.power?.chargePercent
                r.batteryWatts = s.power?.batteryWatts
                r.charging = s.power?.isCharging ?? false
                r.memoryUsedBytes = s.memoryUsed ?? 0
                r.memoryTotalBytes = s.memoryTotal ?? 0
                r.swapUsedBytes = s.memorySwapUsed ?? 0
                r.memoryPressure = pressure
                r.networkInBytesPerSecond = s.netDownBytesPerSec
                r.networkOutBytesPerSecond = s.netUpBytesPerSec
                r.networkInTotalBytes = s.netTotalDown ?? 0
                r.networkOutTotalBytes = s.netTotalUp ?? 0
                self?.reading = r
            }
        }
        SystemMonitor.shared.acquireAnchorStats(id)
    }
    public func release() {
        guard clients > 0 else { return }
        clients -= 1
        guard clients == 0 else { return }
        observing = nil
        SystemMonitor.shared.releaseAnchorStats(id)
    }
}
