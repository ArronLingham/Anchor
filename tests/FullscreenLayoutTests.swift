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
        for screen in [CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: -1920, y: -65, width: 1920, height: 1080)] {
            let panel = GridSolver.fullscreenStackedPanelFrame(screen: screen, panelSize: CGSize(width: 440, height: 260), artworkSide: 300, spacing: 30)
            let cover = GridSolver.fullscreenArtworkFrame(screen: screen, panel: panel, side: 300, spacing: 30, lyricsVisible: false)
            precondition(abs(cover.midX - screen.midX) < 0.01)
            precondition(abs(panel.midX - screen.midX) < 0.01)
            precondition(cover.minY > panel.maxY && screen.contains(cover) && screen.contains(panel))
            let split = GridSolver.fullscreenArtworkFrame(screen: screen, panel: panel, side: 300, spacing: 30, lyricsVisible: true)
            precondition(split.maxX < panel.minX)
        }
        print("Passed fullscreen centering, lyrics split, spanning-column alignment, and saved-layout preservation")
    }
}
