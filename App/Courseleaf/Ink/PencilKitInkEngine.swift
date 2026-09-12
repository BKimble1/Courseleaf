import Foundation
import PencilKit
import UIKit
import DocumentCore

// PencilKit adapter for `DocumentCore.InkEngine` (docs/ARCHITECTURE.md §5).
// Only public PencilKit API is used. Drawing blobs are
// `PKDrawing.dataRepresentation()` and are stored unchanged as assets.
//
// Mask preservation (acceptance A10): a `PKStroke` carries an optional erase
// `mask` in the stroke path's own coordinate space; `PKStroke.transform` maps
// the path *and* the mask into the drawing. Transforming a stroke therefore
// concatenates the transform and never touches the mask; recoloring rebuilds
// the stroke with the same path, transform, mask and random seed and only a
// new `PKInk`.

struct PencilKitInkEngine: InkEngine {
    typealias Drawing = PencilKitDrawing

    init() {}

    var identifier: InkEngineIdentifier { .pencilKit }

    var emptyDrawing: PencilKitDrawing { PencilKitDrawing(drawing: PKDrawing()) }

    func decode(_ data: Data) throws -> PencilKitDrawing {
        do {
            return PencilKitDrawing(drawing: try PKDrawing(data: data))
        } catch {
            throw InkError.undecodable
        }
    }

    func encode(_ drawing: PencilKitDrawing) throws -> Data {
        drawing.drawing.dataRepresentation()
    }
}

/// `InkDrawing` over a `PKDrawing`. Stroke indices address `drawing.strokes`.
struct PencilKitDrawing: InkDrawing {
    var drawing: PKDrawing

    /// Distance in page points between sampled path locations used for hit testing.
    static let sampleDistance: CGFloat = 2

    init(drawing: PKDrawing = PKDrawing()) { self.drawing = drawing }

    init(strokes: [PKStroke]) { self.drawing = PKDrawing(strokes: strokes) }

    static func == (lhs: PencilKitDrawing, rhs: PencilKitDrawing) -> Bool {
        guard lhs.drawing.strokes.count == rhs.drawing.strokes.count else { return false }
        if lhs.drawing.strokes.isEmpty { return true }
        return lhs.drawing.dataRepresentation() == rhs.drawing.dataRepresentation()
    }

    var strokes: [PKStroke] { drawing.strokes }

    // MARK: InkDrawing

    var bounds: PageRect {
        guard !drawing.strokes.isEmpty else { return .zero }
        let b = drawing.bounds
        guard b.width.isFinite, b.height.isFinite, !b.isNull, !b.isInfinite else { return .zero }
        return PageRect(b)
    }

    var strokeCount: Int { drawing.strokes.count }

    var isEmpty: Bool { drawing.strokes.isEmpty }

    func strokeIndices(intersecting rect: PageRect) -> [Int] {
        let rect = rect.standardized
        let cgRect = CGRect(rect)
        return drawing.strokes.indices.filter { i in
            let stroke = drawing.strokes[i]
            // Cheap reject on the rendered bounds first.
            guard stroke.renderBounds.intersects(cgRect) || stroke.renderBounds.isEmpty else { return false }
            return Self.visibleLocations(of: stroke).contains { rect.contains($0) }
        }
    }

    func strokeIndices(inside polygon: [PagePoint]) -> [Int] {
        guard polygon.count >= 3 else { return [] }
        return drawing.strokes.indices.filter { i in
            let points = Self.visibleLocations(of: drawing.strokes[i])
            return !points.isEmpty && points.allSatisfy { Polygon.contains(polygon, $0) }
        }
    }

    func transformingStrokes(_ indices: [Int], by transform: PageTransform) -> PencilKitDrawing {
        var strokes = drawing.strokes
        let cg = CGAffineTransform(transform)
        for i in Set(indices) where strokes.indices.contains(i) {
            // `transform` moves the path and its erase mask together (public API contract).
            strokes[i].transform = strokes[i].transform.concatenating(cg)
        }
        return PencilKitDrawing(strokes: strokes)
    }

    func recoloringStrokes(_ indices: [Int], to color: RGBAColor) -> PencilKitDrawing {
        var strokes = drawing.strokes
        let uiColor = UIColor(color)
        for i in Set(indices) where strokes.indices.contains(i) {
            strokes[i] = Self.recolored(strokes[i], to: uiColor)
        }
        return PencilKitDrawing(strokes: strokes)
    }

    func removingStrokes(_ indices: [Int]) -> PencilKitDrawing {
        let remove = Set(indices)
        let kept = drawing.strokes.enumerated().filter { !remove.contains($0.offset) }.map(\.element)
        return PencilKitDrawing(strokes: kept)
    }

    func extractingStrokes(_ indices: [Int]) -> PencilKitDrawing {
        let strokes = drawing.strokes
        return PencilKitDrawing(strokes: indices.filter { strokes.indices.contains($0) }.map { strokes[$0] })
    }

    func appending(_ other: PencilKitDrawing) -> PencilKitDrawing {
        PencilKitDrawing(strokes: drawing.strokes + other.drawing.strokes)
    }

    // MARK: Helpers

    /// A copy of `stroke` with a new ink colour and the same path, transform,
    /// erase mask and texture seed, so partially erased ink stays erased.
    static func recolored(_ stroke: PKStroke, to color: UIColor) -> PKStroke {
        let ink = PKInk(stroke.ink.inkType, color: color)
        return PKStroke(ink: ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
    }

    /// Page-space locations along the stroke that are visible (inside the erase
    /// mask, if any), sampled every `sampleDistance` points along the path plus
    /// the exact control points, so tiny strokes (dots) still yield a location.
    static func visibleLocations(of stroke: PKStroke) -> [PagePoint] {
        var out: [PagePoint] = []
        let mask = stroke.mask
        let transform = stroke.transform
        func consider(_ local: CGPoint) {
            if let mask, !mask.contains(local) { return }
            out.append(PagePoint(local.applying(transform)))
        }
        for point in stroke.path.interpolatedPoints(by: .distance(sampleDistance)) {
            consider(point.location)
        }
        for point in stroke.path {
            consider(point.location)
        }
        return out
    }

    /// Bounds of only the given strokes (selection bounds), or nil when none.
    func bounds(ofStrokes indices: [Int]) -> PageRect? {
        let sub = extractingStrokes(indices)
        guard !sub.isEmpty else { return nil }
        return sub.bounds
    }
}
