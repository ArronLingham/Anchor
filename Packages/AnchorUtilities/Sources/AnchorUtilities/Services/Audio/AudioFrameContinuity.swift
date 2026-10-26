import AudioToolbox
import Foundation

/// One callback owns this bounded queue. Allocate before starting I/O; never share
/// it between render threads. This preserves packet surplus, not sample-rate
/// conversion: the aggregate must supply source and output at the same rate.
public final class AudioFrameContinuity: @unchecked Sendable {
    public let capacity: Int
    public let channelCapacity: Int
    private let ring: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private var channels = 0
    private var readFrame = 0
    public private(set) var queuedFrames = 0
    public private(set) var callbacks: UInt64 = 0
    public private(set) var shortFrames: UInt64 = 0
    public private(set) var droppedFrames: UInt64 = 0
    public private(set) var mismatchedBuffers: UInt64 = 0
    public private(set) var invalidBuffers: UInt64 = 0
    public private(set) var largestInput = 0
    public private(set) var largestOutput = 0

    public init(channelCapacity: Int, capacity: Int = 8192) {
        self.channelCapacity = max(1, channelCapacity)
        self.capacity = max(1, capacity)
        ring = .allocate(capacity: self.capacity * self.channelCapacity)
        scratch = .allocate(capacity: self.capacity * self.channelCapacity)
        ring.initialize(repeating: 0, count: self.capacity * self.channelCapacity)
        scratch.initialize(repeating: 0, count: self.capacity * self.channelCapacity)
    }

    deinit { ring.deallocate(); scratch.deallocate() }

    /// Returned memory remains valid until the next call. A short result must be
    /// zero-filled by the mapper. Normal equal-size delivery is zero-copy and adds
    /// no latency. Excess frames survive into the next cycle, up to the bound.
    public func prepare(_ source: AudioBuffer, outputFrames: Int) -> AudioBuffer {
        callbacks &+= 1
        let n = Int(source.mNumberChannels)
        let inputFrames = n > 0 ? Int(source.mDataByteSize) / (n * MemoryLayout<Float>.size) : 0
        let requested = max(0, outputFrames)
        largestInput = max(largestInput, inputFrames)
        largestOutput = max(largestOutput, requested)
        if inputFrames != requested { mismatchedBuffers &+= 1 }
        guard n > 0, n <= channelCapacity,
              Int(source.mDataByteSize) % (n * MemoryLayout<Float>.size) == 0 else {
            invalidBuffers &+= 1
            shortFrames &+= UInt64(requested)
            return AudioBuffer(mNumberChannels: UInt32(max(1, n)), mDataByteSize: 0, mData: nil)
        }
        if channels != n {
            droppedFrames &+= UInt64(queuedFrames)
            channels = n
            queuedFrames = 0
            readFrame = 0
        }
        let samples = source.mData?.assumingMemoryBound(to: Float.self)
        let available = samples == nil ? 0 : inputFrames
        if samples == nil { invalidBuffers &+= 1 }
        // Avoid a copy for the overwhelmingly common equal-size path, including
        // a genuinely short source with no previously buffered surplus to draw on.
        if queuedFrames == 0 && available <= requested {
            shortFrames &+= UInt64(requested - available)
            return AudioBuffer(mNumberChannels: source.mNumberChannels,
                               mDataByteSize: UInt32(available * n * MemoryLayout<Float>.size), mData: source.mData)
        }
        let accepted = min(available, capacity - queuedFrames)
        if let samples, accepted > 0 {
            let writeFrame = (readFrame + queuedFrames) % capacity
            let first = min(accepted, capacity - writeFrame)
            ring.advanced(by: writeFrame * n).update(from: samples, count: first * n)
            if first < accepted { ring.update(from: samples.advanced(by: first * n), count: (accepted - first) * n) }
            queuedFrames += accepted
        }
        droppedFrames &+= UInt64(available - accepted)
        let rendered = min(requested, queuedFrames, capacity)
        let first = min(rendered, capacity - readFrame)
        scratch.update(from: ring.advanced(by: readFrame * n), count: first * n)
        if first < rendered { scratch.advanced(by: first * n).update(from: ring, count: (rendered - first) * n) }
        readFrame = (readFrame + rendered) % capacity
        queuedFrames -= rendered
        shortFrames &+= UInt64(requested - rendered)
        return AudioBuffer(mNumberChannels: source.mNumberChannels,
                           mDataByteSize: UInt32(rendered * n * MemoryLayout<Float>.size), mData: scratch)
    }

    public func prepareMissing(outputFrames: Int) -> AudioBuffer {
        prepare(AudioBuffer(mNumberChannels: UInt32(channels > 0 ? channels : channelCapacity), mDataByteSize: 0, mData: nil), outputFrames: outputFrames)
    }

    public func discardQueuedFrames() {
        queuedFrames = 0
        readFrame = 0
    }

    /// Only read after AudioDeviceStop / IOProc destruction has joined the writer.
    public var summary: String {
        "cycles=\(callbacks) mismatches=\(mismatchedBuffers) shortFrames=\(shortFrames) droppedFrames=\(droppedFrames) invalidBuffers=\(invalidBuffers) maxInput=\(largestInput) maxOutput=\(largestOutput) queued=\(queuedFrames)"
    }
}

/// Callback metadata only. Written by one render thread, read after that IOProc
/// is stopped. No audio samples are retained by diagnostics.
public final class AudioRenderTiming: @unchecked Sendable {
    private let secondsPerTick: Double
    private let sampleRate: Double
    private var previousStart: UInt64 = 0
    private var previousFrames = 0
    public private(set) var cycles: UInt64 = 0
    public private(set) var lateCycles: UInt64 = 0
    public private(set) var maximumGap: Double = 0
    public private(set) var maximumDuration: Double = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        secondsPerTick = Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    public func record(start: UInt64, end: UInt64, frames: Int) {
        cycles &+= 1
        maximumDuration = max(maximumDuration, Double(end &- start) * secondsPerTick)
        if previousStart > 0 && previousFrames > 0 && sampleRate > 0 {
            let gap = Double(start &- previousStart) * secondsPerTick
            maximumGap = max(maximumGap, gap)
            if gap > Double(previousFrames) / sampleRate * 1.5 { lateCycles &+= 1 }
        }
        previousStart = start
        previousFrames = frames
    }

    public var summary: String {
        "cycles=\(cycles) lateCycles=\(lateCycles) maxGapMs=\(maximumGap * 1000) maxRenderMs=\(maximumDuration * 1000)"
    }
}
