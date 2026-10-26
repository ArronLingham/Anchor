import AnchorUtilities
import AudioToolbox
import Foundation
import os

/// Captured by one IOProc for its entire lifetime, including crossfade promotion.
/// No mutable queue or fade state is shared between primary and secondary I/O.
nonisolated final class TapRenderContext: @unchecked Sendable {
    let queues: [AudioFrameContinuity]
    let rampFrames: Int
    let timing: AudioRenderTiming
    var fadeFrame = 0
    var wasMuted = false
    var layoutErrors: UInt64 = 0
    var nonSilentCycles: UInt64 = 0

    init(bufferCount: Int, channels: Int, sampleRate: Double) {
        timing = AudioRenderTiming(sampleRate: sampleRate)
        queues = (0..<bufferCount).map { _ in AudioFrameContinuity(channelCapacity: channels) }
        rampFrames = max(1, Int(sampleRate * 0.040))
    }

    /// A linear per-sample ramp starts in the first audible buffer. Once open,
    /// ordinary silence never re-arms it. Muting explicitly arms the next unmute.
    @inline(__always) func gain(frame: Int) -> Float {
        min(1, Float(fadeFrame + frame + 1) / Float(rampFrames))
    }

    func updateMute(_ muted: Bool) {
        if muted {
            if !wasMuted { for queue in queues { queue.discardQueuedFrames() } }
            fadeFrame = 0
        }
        wasMuted = muted
    }

    static func peak(_ buffer: AudioBuffer) -> Float {
        guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
        var result: Float = 0
        for index in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
            result = max(result, abs(samples[index]))
        }
        return min(1, result)
    }

    func tapBufferIndex(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int? {
        guard let queue = queues.first else { return nil }
        for index in stride(from: buffers.count - 1, through: 0, by: -1) {
            if Int(buffers[index].mNumberChannels) == queue.channelCapacity && buffers[index].mData != nil { return index }
        }
        return nil
    }

    func report() {
        let logger = os.Logger(subsystem: "com.arronlingham.Anchor", category: "AudioContinuity")
        logger.info("Non-silent tap cycles: \(self.nonSilentCycles)")
        logger.info("Tap timing: \(self.timing.summary, privacy: .public)")
        if layoutErrors > 0 { logger.error("Unexpected output layout cycles: \(self.layoutErrors)") }
        for (index, queue) in queues.enumerated() where queue.callbacks > 0 {
            logger.info("Tap buffer \(index): \(queue.summary, privacy: .public)")
        }
    }

    static func make(tapID: AudioObjectID, aggregateID: AudioObjectID) throws -> TapRenderContext {
        let format = try tapID.readAudioTapStreamBasicDescription()
        let rate = try aggregateID.readNominalSampleRate()
        // The renderer consumes native interleaved Float32. Reject unsupported
        // contracts before muting the original app instead of interpreting bytes.
        guard isSupported(format, outputRate: rate) else {
            throw NSError(domain: "AnchorAudio", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unsupported tap format or sample-rate mismatch"])
        }
        var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &streamsAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else {
            throw NSError(domain: "AnchorAudio", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot read output streams"])
        }
        var streams = [AudioObjectID](repeating: 0, count: Int(streamSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(aggregateID, &streamsAddress, 0, nil, &streamSize, &streams) == noErr else {
            throw NSError(domain: "AnchorAudio", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot read output streams"])
        }
        for stream in streams {
            let outputFormat: AudioStreamBasicDescription = try stream.read(kAudioStreamPropertyVirtualFormat, defaultValue: AudioStreamBasicDescription())
            guard isSupportedOutput(outputFormat, outputRate: rate) else {
                throw NSError(domain: "AnchorAudio", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unsupported output format or sample-rate mismatch"])
            }
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: kAudioObjectPropertyScopeOutput,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else {
            throw NSError(domain: "AnchorAudio", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot read output layout"])
        }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, memory) == noErr else {
            throw NSError(domain: "AnchorAudio", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot read output layout"])
        }
        let buffers = memory.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers
        guard buffers > 0, buffers <= 32 else {
            throw NSError(domain: "AnchorAudio", code: -4, userInfo: [NSLocalizedDescriptionKey: "Unsupported output layout"])
        }
        return TapRenderContext(bufferCount: Int(buffers), channels: Int(format.mChannelsPerFrame), sampleRate: rate)
    }

    static func isSupportedOutput(_ format: AudioStreamBasicDescription, outputRate: Double) -> Bool {
        let channelStride: UInt32 = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : format.mChannelsPerFrame
        return format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 && format.mBitsPerChannel == 32
            && format.mChannelsPerFrame > 0 && format.mBytesPerFrame == channelStride * 4
            && outputRate.isFinite && outputRate > 0 && format.mSampleRate.isFinite && abs(format.mSampleRate - outputRate) < 1
    }

    static func isSupported(_ format: AudioStreamBasicDescription, outputRate: Double) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && format.mBitsPerChannel == 32 && format.mChannelsPerFrame > 0 && format.mChannelsPerFrame <= 32
            && format.mBytesPerFrame == format.mChannelsPerFrame * 4
            && format.mSampleRate.isFinite && outputRate.isFinite && outputRate > 0
            && abs(format.mSampleRate - outputRate) < 1
    }
}
