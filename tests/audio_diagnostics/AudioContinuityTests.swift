var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    guard condition() else { fatalError("FAIL: \(name)") }
}
func close(_ a: Float, _ b: Float, _ tolerance: Float = 0.00002) -> Bool { abs(a - b) <= tolerance }
func withSource<T>(_ samples: [Float], channels: Int = 2, _ body: (AudioBuffer) -> T) -> T {
    samples.withUnsafeBytes { raw in
        body(AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: UnsafeMutableRawPointer(mutating: raw.baseAddress)))
    }
}
func prepared(_ queue: AudioFrameContinuity, _ samples: [Float], outputFrames: Int, channels: Int = 2) -> [Float] {
    withSource(samples, channels: channels) { source in
        let buffer = queue.prepare(source, outputFrames: outputFrames)
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.mDataByteSize) / 4))
    }
}
func stereo(_ start: Int, _ end: Int) -> [Float] { (start..<end).flatMap { [Float($0), Float(-$0)] } }
let queue = AudioFrameContinuity(channelCapacity: 2, capacity: 16)
check(prepared(queue, stereo(1,9), outputFrames: 4) == stereo(1,5), "surplus renders in order")
check(queue.queuedFrames == 4, "surplus retained")
check(prepared(queue, stereo(9,11), outputFrames: 4) == stereo(5,9), "surplus bridges a short packet")
check(prepared(queue, stereo(11,13), outputFrames: 4) == stereo(9,13), "no reordered or lost frames")
check(queue.shortFrames == 0 && queue.droppedFrames == 0, "balanced variable delivery has no loss")
check(prepared(queue, stereo(13,15), outputFrames: 4) == stereo(13,15), "real starvation returns only valid frames")
check(queue.shortFrames == 2, "starvation accounted")
let overflow = AudioFrameContinuity(channelCapacity: 2, capacity: 8)
_ = prepared(overflow, stereo(0,20), outputFrames: 2)
check(overflow.droppedFrames == 12 && overflow.queuedFrames == 6, "overflow bounded and counted")
_ = prepared(overflow, [1,2,3], outputFrames: 2, channels: 3)
check(overflow.invalidBuffers == 1, "unsupported channel count counted")
overflow.discardQueuedFrames()
check(overflow.queuedFrames == 0, "mute discards stale surplus")
// A null source drains already queued audio before falling back to silence.
let missing = AudioFrameContinuity(channelCapacity: 2)
_ = prepared(missing, stereo(0,8), outputFrames: 4)
let missingOut = missing.prepareMissing(outputFrames: 4)
check(missingOut.mDataByteSize == 32 && missing.queuedFrames == 0, "missing packet uses retained audio")
// Repeated wrap-around with independent input and output chunk sizes.
let wrap = AudioFrameContinuity(channelCapacity: 2, capacity: 16)
var actual: [Float] = []
var next = 0
for index in 0..<1000 {
    let count = index % 2 == 0 ? 7 : 1
    actual += prepared(wrap, stereo(next, next + count), outputFrames: 4)
    next += count
}
check(actual == stereo(0,4000), "1000 variable packets preserve every stereo sample across wraps")
check(wrap.shortFrames == 0 && wrap.droppedFrames == 0, "wrap continuity counters stay clean")

func render(_ source: [Float], frames: Int, context: TapRenderContext, fade: Bool = true,
            volume: inout Float, target: Float = 1, eq: EQProcessor? = nil) -> [Float] {
    var output = [Float](repeating: -99, count: frames * 2)
    withSource(source) { buffer in
        var inputList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
        output.withUnsafeMutableBytes { raw in
            var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            withUnsafeMutablePointer(to: &inputList) { input in
                withUnsafeMutablePointer(to: &outputList) { output in
                    ProductionProbe.processMappedBuffers(inputBuffers: .init(input), outputBuffers: .init(output), targetVol: target, crossfadeMultiplier: 1, context: context, applyStartupFade: fade, rampCoefficient: 0.001, preferredStereoLeft: 0, preferredStereoRight: 1, currentVol: &volume, eqProc: eq, autoEQProc: nil, loudnessEqualizerProc: nil, loudnessCompensatorProc: nil)
                }
            }
        }
    }
    return output
}
let context = TapRenderContext(bufferCount: 1, channels: 2, sampleRate: 48000)
var volume: Float = 1
let rightOnly = (0..<1024).map { $0 % 2 == 0 ? Float(0) : Float(0.25) }
check(withSource(rightOnly) { TapRenderContext.peak($0) } == 0.25, "meter sees right-only stereo")
let startup = render(rightOnly, frames: 512, context: context, volume: &volume)
check(startup[1] > 0 && startup[1023] > startup[1], "first audible buffer fades immediately")
check(zip(stride(from: 1, to: 1021, by: 2), stride(from: 3, to: 1023, by: 2)).allSatisfy { startup[$1] >= startup[$0] && startup[$1] - startup[$0] < 0.001 }, "fade is continuous within buffer")
for _ in 0..<4 { _ = render(rightOnly, frames: 512, context: context, volume: &volume) }
check(context.fadeFrame == context.rampFrames, "startup ramp completes")
for _ in 0..<30 { _ = render([Float](repeating: 0, count: 1024), frames: 512, context: context, volume: &volume) }
let afterSilence = render(rightOnly, frames: 512, context: context, volume: &volume)
check(afterSilence == rightOnly, "quiet passages do not re-arm fade")
context.updateMute(true); context.updateMute(false)
let unmute = render(rightOnly, frames: 512, context: context, volume: &volume)
check(unmute[1] > 0 && unmute[1] < 0.001, "unmute starts sample ramp")
let short = render([Float](repeating: 0.25, count: 4), frames: 4, context: context, fade: false, volume: &volume)
check(short == [0.25,0.25,0.25,0.25,0,0,0,0], "short output tail is initialized")
let carry = TapRenderContext(bufferCount: 1, channels: 2, sampleRate: 48000)
let a = render([0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8], frames: 2, context: carry, fade: false, volume: &volume)
let b = render([0.2,0.1,0.4,0.3], frames: 4, context: carry, fade: false, volume: &volume)
check(a == [0.1,0.2,0.3,0.4] && b == [0.5,0.6,0.7,0.8,0.2,0.1,0.4,0.3], "production mapper carries surplus")

var state = PerAppAudioState()
check(!state.needsProcessing(defaultOutputUID: "speakers"), "flat defaults bypass")
state.outputDeviceUID = "speakers"
check(!state.needsProcessing(defaultOutputUID: "speakers"), "unity pin to default bypasses")
check(state.needsProcessing(defaultOutputUID: "headphones"), "saved pin reengages when default moves")
state.volume = 0.4
check(state.needsProcessing(defaultOutputUID: "speakers"), "attenuation still engages")
state.volume = 1; state.eqEnabled = true; state.eqBandGains[0] = 6
check(state.needsProcessing(defaultOutputUID: "speakers"), "boosted EQ still engages")
state.eqEnabled = false; state.isMuted = true
check(state.needsProcessing(defaultOutputUID: "speakers"), "mute still engages")

var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
check(TapRenderContext.isSupported(format, outputRate: 48000), "Float32 stereo contract accepted")
check(!TapRenderContext.isSupported(format, outputRate: 44100), "unconverted sample-rate mismatch rejected")
format.mBitsPerChannel = 16
check(!TapRenderContext.isSupported(format, outputRate: 48000), "integer-like format rejected")
format.mBitsPerChannel = 32; format.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
check(!TapRenderContext.isSupported(format, outputRate: 48000), "unsupported tap layout rejected")

let boosted = EQSettings(bandGains: [6,6,5,-1,0,0,0,0,0,0])
let coefficients = BiquadMath.coefficientsForAllBands(gains: boosted.clampedGains, sampleRate: 48000)
let preamp = EQProcessor.headroomGain(coefficients: coefficients, sampleRate: 48000)
check(preamp > 0 && preamp < 0.5, "overlapping bass boosts reserve combined headroom")
check(EQProcessor.headroomGain(coefficients: BiquadMath.coefficientsForAllBands(gains: EQSettings.flat.clampedGains, sampleRate: 48000), sampleRate: 48000) == 1, "flat EQ keeps unity")
let eq = EQProcessor(sampleRate: 48000)
eq.updateSettings(boosted)
let tone = (0..<48000).flatMap { frame -> [Float] in
    let x = Float(sin(2 * Double.pi * 62.5 * Double(frame) / 48000) * 0.9)
    return [x,x]
}
var filtered = [Float](repeating: 0, count: tone.count)
tone.withUnsafeBufferPointer { src in filtered.withUnsafeMutableBufferPointer { dst in eq.process(input: src.baseAddress!, output: dst.baseAddress!, frameCount: 48000) } }
check(filtered.dropFirst(24000).allSatisfy { $0.isFinite && abs($0) <= 1 }, "boosted sustained bass stays below full scale after settling")
eq.updateSettings(EQSettings(bandGains: boosted.bandGains, isEnabled: false))
check(!eq.isEnabled, "unchanged gains can disable EQ")
eq.updateSettings(boosted)
check(eq.isEnabled, "unchanged gains can reenable EQ")
print("\(checks) audio continuity checks passed")

func layoutRender(source: [Float], sourceChannels: Int, outputChannels: [Int], preferred: (Int,Int) = (0,1), target: Float = 1, useMixer: Bool = false) -> ([[Float]], Float) {
    let frames = source.count / sourceChannels
    let outputs = AudioBufferList.allocate(maximumBuffers: outputChannels.count)
    defer { free(outputs.unsafeMutablePointer) }
    let storage = outputChannels.map { channels -> UnsafeMutablePointer<Float> in
        let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
        data.initialize(repeating: -99, count: frames * channels)
        return data
    }
    defer { for buffer in storage { buffer.deallocate() } }
    outputs.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(outputChannels.count)
    for index in outputChannels.indices {
        outputs[index] = AudioBuffer(mNumberChannels: UInt32(outputChannels[index]), mDataByteSize: UInt32(frames * outputChannels[index] * 4), mData: storage[index])
    }
    var volume: Float = target == 1 ? 1 : 0.1
    withSource(source, channels: sourceChannels) { buffer in
        var input = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
        withUnsafeMutablePointer(to: &input) {
            if useMixer {
                MixerRender.render(source: buffer, into: outputs, gain: 0.5)
            } else {
                ProductionProbe.processMappedBuffers(inputBuffers: .init($0), outputBuffers: outputs, targetVol: target, crossfadeMultiplier: 1, context: TapRenderContext(bufferCount: outputChannels.count, channels: sourceChannels, sampleRate: 48000), applyStartupFade: false, rampCoefficient: 0.001, preferredStereoLeft: preferred.0, preferredStereoRight: preferred.1, currentVol: &volume, eqProc: nil, autoEQProc: nil, loudnessEqualizerProc: nil, loudnessCompensatorProc: nil)
            }
        }
    }
    return (outputChannels.indices.map { Array(UnsafeBufferPointer(start: storage[$0], count: frames * outputChannels[$0])) }, volume)
}
let split = layoutRender(source: [0.1,0.2,0.3,0.4], sourceChannels: 2, outputChannels: [1,1]).0
check(split == [[0.1,0.3],[0.2,0.4]], "classic interleaved stereo maps to planar output")
let mirrored = layoutRender(source: [Float](repeating: 0.2, count: 1024), sourceChannels: 2, outputChannels: [2,2], target: 0.5)
check(mirrored.0[0] == mirrored.0[1], "multiple output streams use identical gain trajectory")
let single = layoutRender(source: [Float](repeating: 0.2, count: 1024), sourceChannels: 2, outputChannels: [2], target: 0.5)
check(close(mirrored.1, single.1), "gain ramp advances once per cycle across outputs")
let multichannel = layoutRender(source: [0.1,0.2,0.3,0.4], sourceChannels: 2, outputChannels: [6], preferred: (2,3)).0[0]
check(multichannel == [0,0,0.1,0.2,0,0,0,0,0.3,0.4,0,0], "preferred stereo output pair mapped and unused channels silenced")
check(layoutRender(source: [0.1,0.2], sourceChannels: 1, outputChannels: [2]).0 == [[0.1,0.1,0.2,0.2]], "mono duplicates into both front channels")
let advancedSplit = layoutRender(source: [0.1,0.2,0.3,0.4], sourceChannels: 2, outputChannels: [1,1], useMixer: true).0
check(advancedSplit == [[0.05,0.15],[0.1,0.2]], "advanced mixer preserves stereo channel mapping")
let advancedMono = layoutRender(source: [0.1,0.3,0.2,0.4], sourceChannels: 2, outputChannels: [1], useMixer: true).0[0]
check(close(advancedMono[0],0.1) && close(advancedMono[1],0.15), "advanced mixer mono fold-down")
let timing = AudioRenderTiming(sampleRate: 48000)
let now = mach_absolute_time()
timing.record(start: now, end: now + 1, frames: 512)
timing.record(start: now + 1, end: now + 2, frames: 512)
check(timing.cycles == 2 && timing.lateCycles == 0 && timing.maximumDuration > 0, "timing metadata counts cycles without audio capture")
print("\(checks) total audio continuity checks passed")
