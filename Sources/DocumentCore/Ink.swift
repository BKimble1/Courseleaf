import Foundation

/// Identifies the ink engine that produced a drawing blob. The app stores the
/// engine's native serialization (PencilKit `PKDrawing.dataRepresentation()`)
/// as an immutable asset for fidelity; this package never re-encodes it.
public struct InkEngineIdentifier: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Apple PencilKit. Drawing blobs are `PKDrawing` data representations.
    public static let pencilKit = InkEngineIdentifier(rawValue: "pencilkit")
    /// Portable polyline engine used by tests and Linux tooling. See `ReferenceInkEngine`.
    public static let reference = InkEngineIdentifier(rawValue: "reference")
}

/// Operations the editor needs from an ink engine beyond drawing. Each
/// operation returns a new drawing value; strokes are addressed by index into
/// the engine's stroke order at the time of the call. Implementations must
/// preserve per-stroke erase masks through transforms and recoloring, so
/// partially erased ink never reappears (acceptance test A10).
public protocol InkDrawing: Equatable {
    /// Bounding box of all visible ink, in page points. `.zero` when empty.
    var bounds: PageRect { get }
    var strokeCount: Int { get }
    var isEmpty: Bool { get }
    /// Indices of strokes whose visible geometry intersects `rect`.
    func strokeIndices(intersecting rect: PageRect) -> [Int]
    /// Indices of strokes whose visible geometry lies inside the closed polygon (freehand lasso).
    func strokeIndices(inside polygon: [PagePoint]) -> [Int]
    func transformingStrokes(_ indices: [Int], by transform: PageTransform) -> Self
    func recoloringStrokes(_ indices: [Int], to color: RGBAColor) -> Self
    func removingStrokes(_ indices: [Int]) -> Self
    /// Returns only the given strokes (copy / cut source).
    func extractingStrokes(_ indices: [Int]) -> Self
    /// Appends another drawing's strokes (paste).
    func appending(_ other: Self) -> Self
}

public protocol InkEngine {
    associatedtype Drawing: InkDrawing
    var identifier: InkEngineIdentifier { get }
    func decode(_ data: Data) throws -> Drawing
    func encode(_ drawing: Drawing) throws -> Data
    var emptyDrawing: Drawing { get }
}

public enum InkError: Error, Equatable {
    case undecodable
    case engineMismatch(expected: InkEngineIdentifier, found: InkEngineIdentifier)
}

// MARK: - Reference engine

/// A small, fully portable ink model: polyline strokes with width, color,
/// per-stroke transform and an optional erase mask polygon. It exists so the
/// editing, persistence, export-geometry and undo logic can be exercised on
/// Linux with the same semantics the PencilKit adapter must honour:
/// transforms apply to both the path and the mask, recoloring keeps the mask.
public struct ReferenceInkEngine: InkEngine {
    public typealias Drawing = ReferenceDrawing
    public init() {}
    public var identifier: InkEngineIdentifier { .reference }
    public var emptyDrawing: ReferenceDrawing { ReferenceDrawing() }
    public func decode(_ data: Data) throws -> ReferenceDrawing {
        do { return try JSONDecoder().decode(ReferenceDrawing.self, from: data) } catch { throw InkError.undecodable }
    }
    public func encode(_ drawing: ReferenceDrawing) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(drawing)
    }
}

public struct ReferenceStroke: Hashable, Codable, Sendable {
    public enum Tool: String, Codable, Sendable { case pen, pencil, highlighter }
    public var tool: Tool
    public var color: RGBAColor
    public var width: Double
    /// Points in stroke-local coordinates; `transform` maps them to page space.
    public var points: [PagePoint]
    public var transform: PageTransform
    /// Erase mask in stroke-local coordinates: the region of the stroke that
    /// remains visible. `nil` means the whole stroke is visible.
    public var mask: [PagePoint]?

    public init(tool: Tool = .pen, color: RGBAColor = .black, width: Double = 2,
                points: [PagePoint], transform: PageTransform = .identity, mask: [PagePoint]? = nil) {
        self.tool = tool; self.color = color; self.width = width
        self.points = points; self.transform = transform; self.mask = mask
    }

    /// Points in page space after the transform.
    public var pagePoints: [PagePoint] { points.map { transform.apply($0) } }
    /// Visible points: those inside the mask polygon (in local space), then transformed.
    public var visiblePagePoints: [PagePoint] {
        guard let mask else { return pagePoints }
        return points.filter { Polygon.contains(mask, $0) }.map { transform.apply($0) }
    }
    public var bounds: PageRect? { PageRect.bounding(visiblePagePoints)?.insetBy(dx: -width / 2, dy: -width / 2) }
}

public struct ReferenceDrawing: Hashable, Codable, Sendable, InkDrawing {
    public var strokes: [ReferenceStroke]
    public init(strokes: [ReferenceStroke] = []) { self.strokes = strokes }

    public var bounds: PageRect {
        strokes.compactMap(\.bounds).reduce(nil) { acc, r in acc.map { $0.union(r) } ?? r } ?? .zero
    }
    public var strokeCount: Int { strokes.count }
    public var isEmpty: Bool { strokes.isEmpty }

    public func strokeIndices(intersecting rect: PageRect) -> [Int] {
        strokes.indices.filter { i in strokes[i].visiblePagePoints.contains { rect.contains($0) } }
    }
    public func strokeIndices(inside polygon: [PagePoint]) -> [Int] {
        strokes.indices.filter { i in
            let pts = strokes[i].visiblePagePoints
            return !pts.isEmpty && pts.allSatisfy { Polygon.contains(polygon, $0) }
        }
    }
    public func transformingStrokes(_ indices: [Int], by transform: PageTransform) -> ReferenceDrawing {
        var copy = self
        for i in Set(indices) where strokes.indices.contains(i) {
            copy.strokes[i].transform = strokes[i].transform.concatenating(transform)
        }
        return copy
    }
    public func recoloringStrokes(_ indices: [Int], to color: RGBAColor) -> ReferenceDrawing {
        var copy = self
        for i in Set(indices) where strokes.indices.contains(i) { copy.strokes[i].color = color }
        return copy
    }
    public func removingStrokes(_ indices: [Int]) -> ReferenceDrawing {
        let remove = Set(indices)
        return ReferenceDrawing(strokes: strokes.enumerated().filter { !remove.contains($0.offset) }.map(\.element))
    }
    public func extractingStrokes(_ indices: [Int]) -> ReferenceDrawing {
        ReferenceDrawing(strokes: indices.filter { strokes.indices.contains($0) }.map { strokes[$0] })
    }
    public func appending(_ other: ReferenceDrawing) -> ReferenceDrawing { ReferenceDrawing(strokes: strokes + other.strokes) }

    /// Simulates a bitmap eraser: clips each intersecting stroke's visible
    /// region by intersecting its mask with the complement of `rect`.
    /// Strokes entirely inside `rect` are removed. This models partial
    /// erasing closely enough for persistence/undo/export tests.
    public func erasing(rect: PageRect) -> ReferenceDrawing {
        var out: [ReferenceStroke] = []
        for s in strokes {
            let visible = s.visiblePagePoints
            guard visible.contains(where: { rect.contains($0) }) else { out.append(s); continue }
            let inverse = s.transform.inverted() ?? .identity
            let keep = s.points.filter { p in
                let inMask = s.mask.map { Polygon.contains($0, p) } ?? true
                return inMask && !rect.contains(s.transform.apply(p))
            }
            guard !keep.isEmpty else { continue }
            // Local-space mask: the local bounding box minus the erased rect, expressed as the
            // polygon of the kept points' bounding box. Kept explicit for round-trip tests.
            _ = inverse
            var copy = s
            copy.mask = PageRect.bounding(keep).map { $0.insetBy(dx: -0.001, dy: -0.001).corners }
            out.append(copy)
        }
        return ReferenceDrawing(strokes: out)
    }
}

public enum Polygon {
    /// Even-odd point-in-polygon test. Points on an edge count as inside.
    public static func contains(_ polygon: [PagePoint], _ p: PagePoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i], pj = polygon[j]
            if onSegment(p, pi, pj) { return true }
            if (pi.y > p.y) != (pj.y > p.y) {
                let x = (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
    static func onSegment(_ p: PagePoint, _ a: PagePoint, _ b: PagePoint) -> Bool {
        let cross = (p.y - a.y) * (b.x - a.x) - (p.x - a.x) * (b.y - a.y)
        guard abs(cross) < 1e-9 else { return false }
        return p.x >= min(a.x, b.x) - 1e-9 && p.x <= max(a.x, b.x) + 1e-9 && p.y >= min(a.y, b.y) - 1e-9 && p.y <= max(a.y, b.y) + 1e-9
    }
}
