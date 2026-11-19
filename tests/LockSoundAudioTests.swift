import Foundation

@main struct LockSoundAudioTests {
 static func main() async {
  let root = CommandLine.arguments[1]
  let audio=LockSoundAudio { URL(fileURLWithPath:"\(root)/\($0.rawValue).mp3") }
  let start=ProcessInfo.processInfo.systemUptime
  let result: [LockChime:TimeInterval] = await withCheckedContinuation { continuation in
   audio.prepare { offsets in
    precondition(!Thread.isMainThread, "Audio preparation must stay off the UI thread")
    continuation.resume(returning:offsets)
   }
  }
  precondition(result.count == 2, "Both chimes must prepare")
  precondition((0.18...0.23).contains(result[.lock]!), "Lock chime silent lead-in must be skipped")
  precondition((0...0.03).contains(result[.unlock]!), "Unlock chime attack must be preserved")
  print("Both chimes prepared without playback, on a background queue")
  print("Preparation duration:",ProcessInfo.processInfo.systemUptime-start)
  print("Lock silent lead-in skipped:",result[.lock]!)
  print("Unlock silent lead-in skipped:",result[.unlock]!)
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let blocked = LockSoundAudio { _ in
   entered.signal()
   release.wait()
   return nil
  }
  let finished = Task.detached {
   await withCheckedContinuation { continuation in
    blocked.prepare { offsets in continuation.resume(returning: offsets) }
   }
  }
  precondition(entered.wait(timeout: .now() + 3) == .success)
  blocked.play(.lock)
  blocked.setEnabled(false)
  release.signal()
  let oldOffsets = await finished.value
  precondition(oldOffsets.isEmpty, "Disabled preparation must not publish stale offsets")
  let disabled: [LockChime: TimeInterval] = await withCheckedContinuation { continuation in
   blocked.prepare { continuation.resume(returning: $0) }
  }
  precondition(disabled.isEmpty, "Disabled audio must not prepare players")
  audio.setEnabled(false)
  audio.setEnabled(true)
  let restored: [LockChime: TimeInterval] = await withCheckedContinuation { continuation in
   audio.prepare { continuation.resume(returning: $0) }
  }
  precondition(restored.count == 2, "Re-enabled audio must prepare again")
  print("Disable during preparation, queued playback and re-enable checks passed without playback")
 }
}
