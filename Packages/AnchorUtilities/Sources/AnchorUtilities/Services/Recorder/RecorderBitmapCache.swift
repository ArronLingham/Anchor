import CoreGraphics
import Foundation

/// Reusable rasterizations, bounded by decoded bytes rather than image count.
/// A render plan owns the images it uses, so eviction never invalidates an
/// active preview or export. Cache misses simply rasterize again.
final class RecorderBitmapCache {
    private struct Entry {
        let image: CGImage
        let cost: Int
        var lastUse: UInt64
    }

    private let byteLimit: Int
    private let entryLimit: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private var sequence: UInt64 = 0
    private var pressureSource: DispatchSourceMemoryPressure?

    init(byteLimit: Int, entryLimit: Int = 128, observesMemoryPressure: Bool = true) {
        self.byteLimit = max(0, byteLimit)
        self.entryLimit = max(0, entryLimit)
        if observesMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                                 queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in self?.removeAll() }
            source.resume()
            pressureSource = source
        }
    }

    deinit { pressureSource?.cancel() }

    func image(for key: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        sequence &+= 1
        entry.lastUse = sequence
        entries[key] = entry
        return entry.image
    }

    func insert(_ image: CGImage, for key: String) {
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        lock.lock(); defer { lock.unlock() }
        if let previous = entries.removeValue(forKey: key) { bytes -= previous.cost }
        // An oversize picture can still be used by its caller, but keeping a
        // second process-wide reference would exceed the cache's entire budget.
        guard !overflow, cost <= byteLimit, entryLimit > 0 else { return }
        while bytes > byteLimit - cost || entries.count >= entryLimit,
              let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            bytes -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
        sequence &+= 1
        entries[key] = Entry(image: image, cost: cost, lastUse: sequence)
        bytes += cost
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        bytes = 0
    }

    var retainedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }
}
