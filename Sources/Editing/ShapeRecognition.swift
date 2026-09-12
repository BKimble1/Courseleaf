import Foundation
import DocumentCore

// Freehand shape correction: draw a shape, hold at the end of the stroke, and
// the wobbly stroke is replaced by a clean one.
//
// The fitting is portable geometry so it can be tested on Linux against exact
// inputs (`Tests/EditingTests/ShapeRecognitionTests.swift`). The app layer owns
// only the gesture timing and the redraw. Three shapes ship: straight lines,
// ellipses (circles when the radii agree) and rectangles (squares when the
// sides agree). Triangles and arrows are deliberately absent until their
// geometry, selection and export are tested too.
//
// Nothing is corrected unless the fit is decisive: below `minimumConfidence`
// the original stroke is kept exactly as drawn.

public enum RecognizedShape: Hashable, Sendable {
    case line(from: PagePoint, to: PagePoint)
    /// Axis-aligned in a frame rotated by `rotation` radians about `center`.
    case ellipse(center: PagePoint, radiusAlong: Double, radiusAcross: Double, rotation: Double)
    /// Four corners in drawing order; the rectangle may be rotated.
    case rectangle(corners: [PagePoint])

    public var isClosed: Bool { if case .line = self { return false }; return true }

    /// The shape as a polyline in page space, ready to be drawn or compared.
    /// Closed shapes repeat the first point at the end.
    public func polyline(segmentsPerQuadrant: Int = 16) -> [PagePoint] {
        switch self {
        case .line(let a, let b):
            return [a, b]
        case .ellipse(let center, let ra, let rb, let rotation):
            let steps = max(segmentsPerQuadrant, 4) * 4
            let cosR = cos(rotation), sinR = sin(rotation)
            var out: [PagePoint] = []
            out.reserveCapacity(steps + 1)
            for i in 0...steps {
                let t = Double(i) / Double(steps) * 2 * Double.pi
                let u = ra * cos(t), v = rb * sin(t)
                out.append(PagePoint(x: center.x + u * cosR - v * sinR,
                                     y: center.y + u * sinR + v * cosR))
            }
            return out
        case .rectangle(let corners):
            guard corners.count == 4 else { return corners }
            return corners + [corners[0]]
        }
    }

    /// Axis-aligned bounds of the shape's outline.
    public var bounds: PageRect { PageRect.bounding(polyline()) ?? .zero }

    /// Length of the outline. A shape is drawn by travelling its outline once,
    /// so comparing this with the stroke's own length is what separates a
    /// rectangle from a scribble that happens to sit inside the same box.
    public var outlineLength: Double { StrokeGeometry.pathLength(polyline(segmentsPerQuadrant: 24)) }
}

public struct ShapeCorrectionSettings: Hashable, Sendable {
    /// Below this the stroke is left alone.
    public var minimumConfidence: Double = 0.62
    /// Strokes whose longest side is shorter than this are never corrected.
    public var minimumExtent: Double = 18
    /// Snap a nearly-horizontal or nearly-vertical line to the axis, within this
    /// many degrees. A genuinely diagonal line is never straightened onto an axis.
    public var snapsLinesToAxis: Bool = true
    public var axisSnapDegrees: Double = 4
    /// Make an ellipse a circle, or a rectangle a square, when the two
    /// dimensions are within this fraction of each other.
    public var snapsEqualSides: Bool = true
    public var equalSideTolerance: Double = 0.12
    /// The stroke's length divided by the corrected outline's length must fall
    /// in this range: one trip round, not several and not a fragment.
    public var minimumOutlineTravel: Double = 0.6
    public var maximumOutlineTravel: Double = 1.45
    /// Recognise closed shapes at all. Lines are always recognised when enabled.
    public var recognisesEllipses: Bool = true
    public var recognisesRectangles: Bool = true
    public var recognisesLines: Bool = true
    public init() {}
}

public struct ShapeRecognition: Hashable, Sendable {
    public var shape: RecognizedShape
    public var confidence: Double
    public init(shape: RecognizedShape, confidence: Double) {
        self.shape = shape
        self.confidence = confidence
    }
}

public enum ShapeRecognizer {

    /// Best fit for a freehand stroke, or nil when nothing fits well enough.
    public static func recognize(_ points: [PagePoint],
                                 settings: ShapeCorrectionSettings = ShapeCorrectionSettings()) -> ShapeRecognition? {
        guard points.count >= 4 else { return nil }
        let path = StrokeGeometry.resampled(points, spacing: 1.5)
        guard path.count >= 4 else { return nil }
        let bounds = StrokeGeometry.boundingRect(path)
        let extent = max(bounds.width, bounds.height)
        guard extent >= settings.minimumExtent else { return nil }

        let length = StrokeGeometry.pathLength(path)

        var best: ShapeRecognition?
        func consider(_ candidate: ShapeRecognition?) {
            guard let candidate, candidate.confidence >= settings.minimumConfidence else { return }
            // One trip round the outline, give or take the hand's wobble. A
            // stroke that covers the outline several times is a scribble, and a
            // stroke that covers a fraction of it is an unfinished arc.
            let outline = candidate.shape.outlineLength
            guard outline > 1e-6 else { return }
            let travelled = length / outline
            guard travelled >= settings.minimumOutlineTravel, travelled <= settings.maximumOutlineTravel else { return }
            guard let current = best else { best = candidate; return }
            if candidate.confidence > current.confidence { best = candidate }
        }

        let closureGap = path[0].distance(to: path[path.count - 1])
        let isClosed = closureGap <= max(0.22 * extent, 10)

        if settings.recognisesLines, !isClosed { consider(fitLine(path, settings: settings)) }
        if isClosed || closureGap <= 0.5 * length {
            if settings.recognisesEllipses { consider(fitEllipse(path, settings: settings)) }
            if settings.recognisesRectangles { consider(fitRectangle(path, settings: settings)) }
        }
        return best
    }

    // MARK: Line

    static func fitLine(_ path: [PagePoint], settings: ShapeCorrectionSettings) -> ShapeRecognition? {
        let axes = StrokeGeometry.principalAxis(path)
        let along = StrokeGeometry.projections(path, onto: axes.along)
        let across = StrokeGeometry.projections(path, onto: axes.across)
        let axisExtent = StrokeGeometry.extent(along)
        guard axisExtent > 1e-6 else { return nil }

        // A line is drawn in one pass. A stroke that doubles back covers its own
        // span more than once and is not a line however straight it looks.
        let coverage = StrokeGeometry.pathLength(path) / axisExtent
        guard coverage <= 1.3 else { return nil }

        let meanAcross = across.reduce(0, +) / Double(across.count)
        var sumSquares = 0.0
        for value in across { let d = value - meanAcross; sumSquares += d * d }
        let rms = (sumSquares / Double(across.count)).squareRoot()
        let allowed = 0.04 * axisExtent + 1.5
        let confidence = clamp01(1 - rms / allowed)

        guard let lo = along.min(), let hi = along.max() else { return nil }
        func point(_ alongValue: Double) -> PagePoint {
            PagePoint(x: axes.along.x * alongValue + axes.across.x * meanAcross,
                      y: axes.along.y * alongValue + axes.across.y * meanAcross)
        }
        // Keep the direction the student drew in, so an arrow added later points the right way.
        let forwards = along[0] <= along[along.count - 1]
        var from = point(forwards ? lo : hi)
        var to = point(forwards ? hi : lo)
        if settings.snapsLinesToAxis {
            (from, to) = snappedToAxis(from: from, to: to, degrees: settings.axisSnapDegrees)
        }
        return ShapeRecognition(shape: .line(from: from, to: to), confidence: confidence)
    }

    /// Straightens a line onto the horizontal or vertical only when it is
    /// already within `degrees` of it. A 30° line stays a 30° line.
    static func snappedToAxis(from: PagePoint, to: PagePoint, degrees: Double) -> (PagePoint, PagePoint) {
        let dx = to.x - from.x, dy = to.y - from.y
        guard dx != 0 || dy != 0 else { return (from, to) }
        let angle = atan2(dy, dx)
        let tolerance = degrees * Double.pi / 180
        let midX = (from.x + to.x) / 2, midY = (from.y + to.y) / 2
        let half = (dx * dx + dy * dy).squareRoot() / 2
        // Nearest multiple of 90 degrees.
        let quarter = (angle / (Double.pi / 2)).rounded() * (Double.pi / 2)
        var delta = angle - quarter
        while delta > Double.pi { delta -= 2 * Double.pi }
        while delta < -Double.pi { delta += 2 * Double.pi }
        guard abs(delta) <= tolerance else { return (from, to) }
        let ux = cos(quarter), uy = sin(quarter)
        return (PagePoint(x: midX - ux * half, y: midY - uy * half),
                PagePoint(x: midX + ux * half, y: midY + uy * half))
    }

    // MARK: Ellipse

    static func fitEllipse(_ path: [PagePoint], settings: ShapeCorrectionSettings) -> ShapeRecognition? {
        let center = StrokeGeometry.centroid(path)
        let axes = StrokeGeometry.principalAxis(path)
        let centred = path.map { PagePoint(x: $0.x - center.x, y: $0.y - center.y) }
        let u = StrokeGeometry.projections(centred, onto: axes.along)
        let v = StrokeGeometry.projections(centred, onto: axes.across)
        var ra = StrokeGeometry.extent(u) / 2
        var rb = StrokeGeometry.extent(v) / 2
        guard ra > 1e-6, rb > 1e-6 else { return nil }
        // The extents are biased outward by the hand's wobble, which would make
        // every hand-drawn circle look like a bad fit. One refinement pass
        // rescales the radii so the mean sampled radius sits on the curve.
        var ratioSum = 0.0
        for i in path.indices {
            let du = u[i] / ra, dv = v[i] / rb
            ratioSum += (du * du + dv * dv).squareRoot()
        }
        let meanRatio = ratioSum / Double(path.count)
        if meanRatio.isFinite, meanRatio > 0.2, meanRatio < 5 { ra *= meanRatio; rb *= meanRatio }
        if settings.snapsEqualSides, abs(ra - rb) <= settings.equalSideTolerance * max(ra, rb) {
            let r = (ra + rb) / 2
            ra = r; rb = r
        }
        // Residual of the implicit ellipse equation, scaled back to page points.
        var sum = 0.0
        for i in path.indices {
            let du = u[i] / ra, dv = v[i] / rb
            let radius = (du * du + dv * dv).squareRoot()
            sum += abs(radius - 1)
        }
        let meanRelative = sum / Double(path.count)
        let scale = (ra + rb) / 2
        let error = meanRelative * scale
        let allowed = 0.07 * scale + 1.5
        let confidence = clamp01(1 - error / allowed)
        let rotation = atan2(axes.along.y, axes.along.x)
        return ShapeRecognition(shape: .ellipse(center: center, radiusAlong: ra, radiusAcross: rb, rotation: rotation),
                                confidence: confidence)
    }

    // MARK: Rectangle

    static func fitRectangle(_ path: [PagePoint], settings: ShapeCorrectionSettings) -> ShapeRecognition? {
        let axes = StrokeGeometry.principalAxis(path)
        // A rectangle's principal axis follows its longer side, so the box in
        // that rotated frame is the rectangle the student meant.
        let u = StrokeGeometry.projections(path, onto: axes.along)
        let v = StrokeGeometry.projections(path, onto: axes.across)
        guard let u0 = u.min(), let u1 = u.max(), let v0 = v.min(), let v1 = v.max() else { return nil }
        var halfU = (u1 - u0) / 2, halfV = (v1 - v0) / 2
        let midU = (u0 + u1) / 2, midV = (v0 + v1) / 2
        guard halfU > 1e-6, halfV > 1e-6 else { return nil }
        if settings.snapsEqualSides, abs(halfU - halfV) <= settings.equalSideTolerance * max(halfU, halfV) {
            let h = (halfU + halfV) / 2
            halfU = h; halfV = h
        }
        func point(_ du: Double, _ dv: Double) -> PagePoint {
            PagePoint(x: axes.along.x * (midU + du) + axes.across.x * (midV + dv),
                      y: axes.along.y * (midU + du) + axes.across.y * (midV + dv))
        }
        let corners = [point(-halfU, -halfV), point(halfU, -halfV), point(halfU, halfV), point(-halfU, halfV)]
        let outline = corners + [corners[0]]
        var sum = 0.0
        for p in path { sum += StrokeGeometry.distance(from: p, toPolyline: outline) }
        let error = sum / Double(path.count)
        let scale = (halfU + halfV)
        let allowed = 0.06 * scale + 1.5
        var confidence = clamp01(1 - error / allowed)
        // A circle also sits inside its box; penalise a rectangle fit whose
        // corners carry no ink, so an ellipse wins where it should.
        let cornerOccupancy = corners.filter { corner in
            path.contains { $0.distance(to: corner) <= 0.22 * min(halfU, halfV) + 6 }
        }.count
        if cornerOccupancy < 3 { confidence *= 0.55 }
        return ShapeRecognition(shape: .rectangle(corners: corners), confidence: confidence)
    }

    static func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }
}
