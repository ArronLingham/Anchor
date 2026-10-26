// One-shot, output-only diagnostic. It adds a silent client to the current
// default output; it does not capture audio or change volume/device preferences.
// Four 3-second trials alternate queued/direct callbacks. Initial 0.5s is
// excluded from gap statistics. This is not an end-to-end process-tap test.
// Compile standalone with the installed Swift 6 toolchain.
import Foundation
import CoreAudio
import Synchronization
import Darwin

struct Stats {
    var count: UInt64 = 0
    var queued: UInt64 = 0
    var previous: UInt64 = 0
    var maxGap: UInt64 = 0
    var firstPort: thread_t = 0
    var firstTime: UInt64 = 0
    var gapCount: Int = 0
}
func read<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
}
var device = AudioDeviceID(0)
guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device) == noErr else { fatalError("no output") }
var rate: Float64 = 0
var frames: UInt32 = 0
_ = read(device, kAudioDevicePropertyNominalSampleRate, &rate)
_ = read(device, kAudioDevicePropertyBufferFrameSize, &frames)
print("Output device \(device), rate \(rate), hardware buffer frames \(frames), nominal cycle ms \(Double(frames) / rate * 1000)")
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
for queued in [true, false, false, true] {
    let queue = DispatchQueue(label: "anchor.audio.diagnostic", qos: .userInitiated)
    let key = DispatchSpecificKey<UInt8>()
    queue.setSpecific(key: key, value: 1)
    let observedThread = Atomic<UInt32>(0)
    let stats = UnsafeMutablePointer<Stats>.allocate(capacity: 1)
    stats.initialize(to: Stats())
    let gaps = UnsafeMutablePointer<UInt64>.allocate(capacity: 1024)
    gaps.initialize(repeating: 0, count: 1024)
    let warmupTicks = UInt64(0.5 * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    var proc: AudioDeviceIOProcID?
    let made = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queued ? queue : nil) { _, _, _, output, _ in
        let now = mach_absolute_time()
        if stats.pointee.count == 0 {
            stats.pointee.firstPort = pthread_mach_thread_np(pthread_self())
            observedThread.store(stats.pointee.firstPort, ordering: .releasing)
            stats.pointee.firstTime = now
        }
        if DispatchQueue.getSpecific(key: key) == 1 { stats.pointee.queued += 1 }
        if now - stats.pointee.firstTime > warmupTicks && stats.pointee.previous != 0 && stats.pointee.gapCount < 1024 {
            let gap = now - stats.pointee.previous
            stats.pointee.maxGap = max(stats.pointee.maxGap, gap)
            gaps[stats.pointee.gapCount] = gap
            stats.pointee.gapCount += 1
        }
        stats.pointee.previous = now
        stats.pointee.count += 1
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }
    guard made == noErr, let proc else { fatalError("create \(made)") }
    let started = AudioDeviceStart(device, proc)
    guard started == noErr else { fatalError("start \(started)") }
    Thread.sleep(forTimeInterval: 3)
    var policy = thread_time_constraint_policy_data_t()
    var policyCount = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
    var policyDefault: boolean_t = 0
    let policyStatus = withUnsafeMutablePointer(to: &policy) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(policyCount)) {
            thread_policy_get(observedThread.load(ordering: .acquiring), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, &policyCount, &policyDefault)
        }
    }
    print("Thread timing policy: status=\(policyStatus), default=\(policyDefault), period=\(policy.period), computation=\(policy.computation), constraint=\(policy.constraint)")
    _ = AudioDeviceStop(device, proc)
    _ = AudioDeviceDestroyIOProcID(device, proc)
    let value = stats.pointee
    let maxGapMS = Double(value.maxGap) * Double(timebase.numer) / Double(timebase.denom) / 1e6
    let values = Array(UnsafeBufferPointer(start: gaps, count: value.gapCount)).map { Double($0) * Double(timebase.numer) / Double(timebase.denom) / 1e6 }.sorted()
    let p99 = values.isEmpty ? 0 : values[min(values.count - 1, Int(Double(values.count) * 0.99))]
    let late = values.filter { $0 > Double(frames) / rate * 1000 * 1.5 }.count
    print("\(queued ? "dispatch queue" : "direct HAL"): callbacks=\(value.count), on supplied queue=\(value.queued), post-warmup gaps=\(value.gapCount), max ms=\(maxGapMS), p99 ms=\(p99), gaps >1.5 cycles=\(late)")
    gaps.deinitialize(count: 1024)
    gaps.deallocate()
    stats.deinitialize(count: 1)
    stats.deallocate()
}
