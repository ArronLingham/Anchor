import AppKit
import Defaults

@main
struct MediaVisualizerTests {
    @MainActor
    static func main() {
        let size = NSSize(width: 80, height: 20)
        let decorative = TestDecorativeSpectrum(frame: NSRect(origin: .zero, size: size))
        let real = TestSpectrum(frame: NSRect(origin: .zero, size: size))

        decorative.layout()
        real.layout()
        checkMinimum(decorative)
        checkMinimum(real)
        precondition(AudioTap.shared.leases == 0)

        real.setPlaying(true)
        decorative.setPlaying(true)
        precondition(AudioTap.shared.leases == 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(real.layer?.sublayers?.allSatisfy { $0.transform.m22 > 0.2 } == true)
        precondition(decorative.layer?.sublayers?.allSatisfy { $0.animation(forKey: "scaleY") != nil } == true)

        real.setPlaying(false)
        decorative.setPlaying(false)
        checkMinimum(real)
        checkMinimum(decorative)
        precondition(AudioTap.shared.leases == 0)

        Defaults[.visualizerBarCount] = 7
        Defaults[.coloredSpectrogram] = true
        real.refreshAppearance()
        decorative.refreshAppearance()
        checkMinimum(real, count: 7)
        checkMinimum(decorative, count: 7)

        real.setFrameSize(NSSize(width: 140, height: 28))
        decorative.setFrameSize(NSSize(width: 140, height: 28))
        real.layout()
        decorative.layout()
        checkMinimum(real, count: 7)
        checkMinimum(decorative, count: 7)
        precondition(AudioTap.shared.leases == 0)

        real.visible = false
        real.setPlaying(true)
        precondition(AudioTap.shared.leases == 0)
        print("Paused visualizers stay at minimum through start, pause, resize and bar-count changes")
    }

    @MainActor
    private static func checkMinimum(_ view: NSView, count: Int = 4) {
        guard let bars = view.layer?.sublayers else { preconditionFailure("Missing spectrum layers") }
        precondition(bars.count == count)
        precondition(bars.allSatisfy { abs($0.transform.m22 - 0.2) < 0.0001 })
        precondition(bars.allSatisfy { $0.animationKeys()?.isEmpty ?? true })
    }
}

private final class TestDecorativeSpectrum: AudioSpectrum {
    override var isVisibleForAnimation: Bool { true }
}

private final class TestSpectrum: RealTimeAudioSpectrum {
    var visible = true
    override var isVisibleForAnimation: Bool { visible }
}

final class AudioTap {
    static let shared = AudioTap()
    private(set) var leases = 0

    func acquire() { leases += 1 }
    func release() { leases -= 1 }
    func getSmoothedMagnitudes() -> [Float] { Array(repeating: 1, count: 16) }
}

final class MusicManager {
    static let shared = MusicManager()
    let avgColor = NSColor.red
}

enum SurfaceStyle {
    static func vivid(_ color: NSColor) -> NSColor { color }
}

extension Defaults.Key where Value == Int {
    static var visualizerBarCount: Self { .init("barCount", default: 4) }
}

extension Defaults.Key where Value == Bool {
    static var coloredSpectrogram: Self { .init("colored", default: false) }
}
