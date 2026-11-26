import CoreGraphics

/// Layout measured in the panel's content coordinates, with y increasing downward.
struct VinylLayout {
    static let minimumSize = CGSize(width: 144, height: 96)

    enum Axis: Equatable {
        case vertical, horizontal

        static func choose(for size: CGSize, retaining previous: Self?) -> Self {
            let ratio = size.width / max(size.height, 1)
            let threshold = previous == .horizontal ? 1.08 : 1.20
            return ratio >= threshold ? .horizontal : .vertical
        }
    }

    let recordCenter: CGPoint
    let recordSide: CGFloat
    let controlsFrame: CGRect
    let scale: CGFloat
    let showsMetadata: Bool
    let showsBar: Bool
    let metadataHeight: CGFloat
    let transportHeight: CGFloat
    let barHeight: CGFloat

    init(size: CGSize, axis: Axis, showsBar: Bool) {
        let inset = min(22, max(12, min(size.width, size.height) * 0.068))
        let width = max(1, size.width - 2 * inset)
        let height = max(1, size.height - 2 * inset)
        let gap = min(19, max(9, min(width, height) * 0.069))
        let horizontal = axis == .horizontal
        let recordColumn = min(height, width * 0.46)
        let detailWidth = horizontal ? max(1, width - recordColumn - gap) : width * 0.90
        scale = min(290, horizontal ? min(detailWidth * 1.24, height * 2.2) : detailWidth)
        showsMetadata = horizontal ? detailWidth >= 150 && height >= 107 : width >= 178 && height >= 202
        self.showsBar = showsBar
        metadataHeight = max(31, scale * 0.14)
        transportHeight = max(28, scale * 0.155)
        barHeight = max(22, scale * 0.096)
        let detailsHeight = transportHeight
            + (showsMetadata ? metadataHeight + 5 : 0)
            + (showsBar ? barHeight + 5 : 0)
        let detailsOrigin: CGPoint

        if horizontal {
            recordSide = max(1, recordColumn * 0.88)
            recordCenter = CGPoint(x: inset + recordColumn / 2, y: size.height / 2)
            detailsOrigin = CGPoint(x: inset + recordColumn + gap, y: (size.height - detailsHeight) / 2)
        } else {
            let recordRow = max(1, height - gap - detailsHeight)
            recordSide = min(width * 0.84, recordRow * 0.88)
            let stackHeight = recordSide / 0.88 + gap + detailsHeight
            let stackTop = (size.height - stackHeight) / 2
            recordCenter = CGPoint(x: size.width / 2, y: stackTop + recordSide / 1.76)
            detailsOrigin = CGPoint(x: (size.width - detailWidth) / 2, y: stackTop + stackHeight - detailsHeight)
        }

        controlsFrame = CGRect(origin: detailsOrigin, size: CGSize(width: detailWidth, height: detailsHeight))
    }
}

/// Each handle moves a single pair of edges, clamping against the opposite edge.
struct VinylResizeEdges: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
    static let bottom = Self(rawValue: 1 << 2)
    static let top = Self(rawValue: 1 << 3)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(at point: CGPoint, in bounds: CGRect, margin: CGFloat = 10) {
        self = []
        guard bounds.contains(point) else { return }
        if point.x - bounds.minX <= margin { insert(.left) }
        if bounds.maxX - point.x <= margin { insert(.right) }
        if point.y - bounds.minY <= margin { insert(.bottom) }
        if bounds.maxY - point.y <= margin { insert(.top) }
    }

    func frame(from start: CGRect, delta: CGPoint) -> CGRect {
        let minimum = VinylLayout.minimumSize
        let left = contains(.left) ? min(start.maxX - minimum.width, start.minX + delta.x) : start.minX
        let right = contains(.right) ? max(start.minX + minimum.width, start.maxX + delta.x) : start.maxX
        let bottom = contains(.bottom) ? min(start.maxY - minimum.height, start.minY + delta.y) : start.minY
        let top = contains(.top) ? max(start.minY + minimum.height, start.maxY + delta.y) : start.maxY
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}
