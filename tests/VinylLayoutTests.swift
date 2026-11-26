import CoreGraphics

@main
enum VinylLayoutTests {
    static func main() {
        let start = CGRect(x: 40, y: 70, width: 300, height: 190)
        let bounds = CGRect(origin: .zero, size: start.size)
        let handles: [(CGPoint, VinylResizeEdges)] = [
            (.init(x: 3, y: 90), .left), (.init(x: 297, y: 90), .right),
            (.init(x: 150, y: 3), .bottom), (.init(x: 150, y: 187), .top),
            (.init(x: 3, y: 3), [.left, .bottom]), (.init(x: 297, y: 3), [.right, .bottom]),
            (.init(x: 3, y: 187), [.left, .top]), (.init(x: 297, y: 187), [.right, .top]),
        ]
        for (point, expected) in handles {
            let edges = VinylResizeEdges(at: point, in: bounds)
            precondition(edges == expected)
            for delta in [CGPoint(x: 70, y: 40), CGPoint(x: 500, y: 500), CGPoint(x: -500, y: -500)] {
                let resized = edges.frame(from: start, delta: delta)
                precondition(resized.width >= VinylLayout.minimumSize.width)
                precondition(resized.height >= VinylLayout.minimumSize.height)
                if !edges.contains(.left) { precondition(resized.minX == start.minX) }
                if !edges.contains(.right) { precondition(resized.maxX == start.maxX) }
                if !edges.contains(.bottom) { precondition(resized.minY == start.minY) }
                if !edges.contains(.top) { precondition(resized.maxY == start.maxY) }
            }
        }
        precondition(VinylResizeEdges(at: CGPoint(x: 150, y: 90), in: bounds).isEmpty)
        let middle = CGSize(width: 226, height: 200)
        precondition(VinylLayout.Axis.choose(for: middle, retaining: .vertical) == .vertical)
        precondition(VinylLayout.Axis.choose(for: middle, retaining: .horizontal) == .horizontal)
        precondition(VinylLayout.Axis.choose(for: CGSize(width: 360, height: 200), retaining: .vertical) == .horizontal)
        precondition(VinylLayout.Axis.choose(for: CGSize(width: 200, height: 360), retaining: .horizontal) == .vertical)

        var layouts = 0
        for width in stride(from: 144, through: 900, by: 12) {
            for height in stride(from: 96, through: 720, by: 12) {
                let size = CGSize(width: CGFloat(width), height: CGFloat(height))
                let frame = CGRect(origin: .zero, size: size)
                for previous in [VinylLayout.Axis.vertical, .horizontal] {
                    for bar in [true, false] {
                        let axis = VinylLayout.Axis.choose(for: size, retaining: previous)
                        let layout = VinylLayout(size: size, axis: axis, showsBar: bar)
                        let side = layout.recordSide
                        let record = CGRect(x: layout.recordCenter.x - side / 2, y: layout.recordCenter.y - side / 2,
                                            width: side, height: side)
                        precondition(side > 0 && frame.contains(record) && frame.contains(layout.controlsFrame))
                        precondition(!record.intersects(layout.controlsFrame))
                        precondition(layout.showsBar == bar)
                        layouts += 1
                    }
                }
            }
        }
        precondition(!VinylLayout(size: CGSize(width: 285, height: 99), axis: .horizontal, showsBar: true).showsMetadata)
        precondition(VinylLayout(size: CGSize(width: 430, height: 220), axis: .horizontal, showsBar: true).showsMetadata)
        precondition(VinylLayout(size: CGSize(width: 260, height: 350), axis: .vertical, showsBar: true).showsMetadata)
        print("All eight Vinyl resize handles and \(layouts) layout combinations passed")
    }
}
