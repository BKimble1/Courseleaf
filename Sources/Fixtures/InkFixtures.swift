import Foundation
import DocumentCore

/// Deterministic pseudo-random generator (SplitMix64) so fixtures are
/// identical on every platform and run.
public struct FixtureRandom: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }
}

/// Reference-engine ink fixtures for persistence, editing and export tests.
public enum InkFixtures {
    static let palette: [RGBAColor] = [
        .black, RGBAColor(hex: "#1F5FBF")!, RGBAColor(hex: "#C0392B")!, RGBAColor(hex: "#2E8B57")!, RGBAColor(hex: "#F2C94C")!,
    ]

    /// `strokeCount` short wavy strokes spread over a US Letter page in a grid
    /// pattern with seeded jitter. Deterministic for a given seed; every
    /// visible point lies inside the page.
    public static func denseDrawing(strokeCount: Int, seed: UInt64 = 1, pageSize: PageSize = .letter) -> ReferenceDrawing {
        precondition(strokeCount >= 0)
        guard strokeCount > 0 else { return ReferenceDrawing() }
        var rng = FixtureRandom(seed: seed)
        let inset = 24.0
        let usable = PageRect(origin: .zero, size: pageSize).insetBy(dx: inset, dy: inset)
        let columns = max(1, Int(Double(strokeCount).squareRoot().rounded(.up)))
        let rows = max(1, (strokeCount + columns - 1) / columns)
        let cellW = usable.width / Double(columns), cellH = usable.height / Double(rows)
        var strokes: [ReferenceStroke] = []
        strokes.reserveCapacity(strokeCount)
        for i in 0..<strokeCount {
            let col = i % columns, row = i / columns
            let cell = PageRect(x: usable.minX + Double(col) * cellW, y: usable.minY + Double(row) * cellH, width: cellW, height: cellH)
            let length = max(4, min(cell.width, cell.height) * 0.8)
            let startX = rng.double(in: cell.minX...(max(cell.minX, cell.maxX - length)))
            let midY = rng.double(in: (cell.minY + length * 0.15)...(max(cell.minY + length * 0.15, cell.maxY - length * 0.15)))
            let amplitude = min(length * 0.1, cell.height * 0.1)
            let pointCount = 8
            var points: [PagePoint] = []
            for k in 0..<pointCount {
                let t = Double(k) / Double(pointCount - 1)
                let x = startX + t * length
                let y = midY + amplitude * sin(t * .pi * 2 + rng.double(in: -0.3...0.3))
                points.append(PagePoint(x: min(max(x, usable.minX), usable.maxX), y: min(max(y, usable.minY), usable.maxY)))
            }
            let toolIndex = rng.int(in: 0...9)
            let tool: ReferenceStroke.Tool = toolIndex < 7 ? .pen : (toolIndex < 9 ? .pencil : .highlighter)
            let width: Double = tool == .highlighter ? 8 : rng.double(in: 1.0...3.0)
            strokes.append(ReferenceStroke(tool: tool, color: palette[rng.int(in: 0...(palette.count - 1))], width: width, points: points))
        }
        return ReferenceDrawing(strokes: strokes)
    }

    /// Three strokes: one untouched, one partially erased (a mask keeps only its
    /// left half), one moved by a transform after being partially erased. Used
    /// to prove erase masks survive transforms, recoloring and round trips (A10).
    public static func partiallyErasedSample() -> ReferenceDrawing {
        let untouched = ReferenceStroke(tool: .pen, color: .black, width: 2,
                                        points: (0...10).map { PagePoint(x: 100 + Double($0) * 10, y: 100) })
        let long = ReferenceStroke(tool: .pen, color: RGBAColor(hex: "#1F5FBF")!, width: 3,
                                   points: (0...20).map { PagePoint(x: 100 + Double($0) * 10, y: 200 + (Double($0).truncatingRemainder(dividingBy: 2)) * 4) })
        let base = ReferenceDrawing(strokes: [untouched, long])
        // Erase the right half of the long stroke: page rect x >= 200.
        let erased = base.erasing(rect: PageRect(x: 200, y: 150, width: 200, height: 100))
        // A third stroke: partially erased, then moved down by 100 pt; its mask must move with it.
        let moved = ReferenceDrawing(strokes: [ReferenceStroke(tool: .pencil, color: RGBAColor(hex: "#C0392B")!, width: 2,
                                                               points: (0...20).map { PagePoint(x: 300 - Double($0) * 8, y: 300) })])
            .erasing(rect: PageRect(x: 140, y: 280, width: 80, height: 40))
            .transformingStrokes([0], by: .translation(x: 0, y: 100))
        return erased.appending(moved)
    }
}
