import Foundation
import CoreGraphics
@main struct FullscreenLayoutTests {
    static func main() {
        for size in [CGSize(width: 1366, height: 768), CGSize(width: 1920, height: 1080)] {
            let original = SurfaceLayout.defaultLockFull
            let hidden = GridSolver.fullscreenLayout(original, lyricsVisible: false)
            let centered = GridSolver.solveFullscreen(layout: hidden, available: size, hovering: false)
            let art = centered.elements.first { $0.placement.element == .artwork }!
            precondition(abs(art.frame.midX - size.width / 2) < 0.01)
            precondition(!centered.elements.contains { $0.placement.element == .lyrics })
            let visible = GridSolver.solveFullscreen(layout: GridSolver.fullscreenLayout(original, lyricsVisible: true), available: size, hovering: false)
            let splitArt = visible.elements.first { $0.placement.element == .artwork }!
            let lyrics = visible.elements.first { $0.placement.element == .lyrics }!
            precondition(splitArt.frame.midX < size.width / 2)
            precondition(lyrics.frame.midX > size.width / 2)
            let title = visible.elements.first { $0.placement.element == .title }!
            precondition(abs(title.frame.midX - splitArt.frame.midX) < 0.01)
            precondition(original.placements.contains { $0.element == .lyrics })
        }
        print("Passed fullscreen centering, lyrics split, spanning-column alignment, and saved-layout preservation")
    }
}
