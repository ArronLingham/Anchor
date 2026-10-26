// Local playback fixture, never part of Anchor. A distinct app bundle lets both
// mixers identify the test source without relying on a terminal's responsible PID.
import AppKit
import AVFAudio

let app = NSApplication.shared
app.setActivationPolicy(.regular)
guard CommandLine.arguments.count > 1 else { fatalError("Pass a local audio file") }
let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
player.volume = 0.2
player.numberOfLoops = 0
guard player.play() else { fatalError("Could not start local playback") }
DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 1) { app.terminate(nil) }
app.run()
