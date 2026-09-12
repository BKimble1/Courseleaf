import Foundation
import DocumentCore

// Portable polyline geometry shared by the gesture recognisers (scribble erase,
// shape correction) and by hit testing that must not fall back to bounding
// rectangles. Everything here is page space (PDF points, origin top-left of the
// visible page) and free of UIKit, so the same code runs on Linux under
// `swift test` and inside the app.

public enum StrokeGeometry {

    // MARK: Basic measures

    /// Summed distance between consecutive points.
    public static func pathLength(_ points: [PagePoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count { total += points[i - 1].distance(to: points[i]) }
        return total
    }

    public static func boundingRect(_ points: [PagePoint]) -> PageRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return PageRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func centroid(_ points: [PagePoint]) -> PagePoint {
        guard !points.isEmpty else { return PagePoint(x: 0, y: 0) }
        var sx = 0.0, sy = 0.0
        for p in points { sx += p.x; sy += p.y }
        return PagePoint(x: sx / Double(points.count), y: sy / Double(points.count))
    }

    /// Resamples a polyline to points spaced `spacing` apart, so downstream
    /// measures do not depend on how densely the device sampled the touch.
    public static func resampled(_ points: [PagePoint], spacing: Double) -> [PagePoint] {
        guard spacing > 0, points.count > 1 else { return points }
        var out: [PagePoint] = [points[0]]
        var carried = 0.0
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            var segment = a.distance(to: b)
            guard segment > 0 else { continue }
            var start = a
            while carried + segment >= spacing {
                let t = (spacing - carried) / segment
                let next = PagePoint(x: start.x + (b.x - start.x) * t, y: start.y + (b.y - start.y) * t)
                out.append(next)
                start = next
                segment = start.distance(to: b)
                carried = 0
            }
            carried += segment
        }
        if let last = points.last, out.last.map({ $0.distance(to: last) > 1e-9 }) ?? true { out.append(last) }
        return out
    }

    // MARK: Principal axis

    /// The unit direction of greatest variance (first principal component) and
    /// the perpendicular, computed from the 2x2 covariance matrix. Returns the
    /// x axis for degenerate input so callers never divide by zero.
    public static func principalAxis(_ points: [PagePoint]) -> (along: PagePoint, across: PagePoint) {
        let c = centroid(points)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points {
            let dx = p.x - c.x, dy = p.y - c.y
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let n = Double(max(points.count, 1))
        sxx /= n; syy /= n; sxy /= n
        // Largest eigenvalue of [[sxx, sxy], [sxy, syy]].
        let trace = sxx + syy
        let diff = sxx - syy
        let root = (diff * diff + 4 * sxy * sxy).squareRoot()
        let lambda = (trace + root) / 2
        var vx = sxy
        var vy = lambda - sxx
        if abs(vx) < 1e-12 && abs(vy) < 1e-12 {
            vx = 1; vy = 0
        }
        let length = (vx * vx + vy * vy).squareRoot()
        guard length > 1e-12 else { return (PagePoint(x: 1, y: 0), PagePoint(x: 0, y: 1)) }
        let along = PagePoint(x: vx / length, y: vy / length)
        return (along, PagePoint(x: -along.y, y: along.x))
    }

    /// Scalar projections of `points` onto a unit direction through the origin.
    public static func projections(_ points: [PagePoint], onto axis: PagePoint) -> [Double] {
        points.map { $0.x * axis.x + $0.y * axis.y }
    }

    /// Difference between the largest and smallest projection.
    public static func extent(_ values: [Double]) -> Double {
        guard let lo = values.min(), let hi = values.max() else { return 0 }
        return hi - lo
    }

    /// Direction reversals in a 1-D signal, counting only reversals that end a
    /// run at least `minimumRun` long. Jitter inside a run is ignored, so the
    /// count answers "how many times did the pen genuinely double back".
    public static func significantReversals(_ values: [Double], minimumRun: Double) -> Int {
        guard values.count > 2, minimumRun > 0 else { return 0 }
        var reversals = 0
        var direction = 0            // -1, 0 or +1
        var anchor = values[0]       // where the current run began
        for value in values.dropFirst() {
            let delta = value - anchor
            if direction == 0 {
                if abs(delta) >= minimumRun { direction = delta > 0 ? 1 : -1; anchor = value }
                continue
            }
            if (delta > 0 ? 1 : -1) == direction {
                // Still going the same way: move the anchor forward.
                anchor = value
            } else if abs(delta) >= minimumRun {
                reversals += 1
                direction = -direction
                anchor = value
            }
        }
        return reversals
    }

    // MARK: Distance

    /// Shortest distance from `point` to the segment a-b.
    public static func distance(from point: PagePoint, toSegment a: PagePoint, _ b: PagePoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-12 else { return point.distance(to: a) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        return point.distance(to: PagePoint(x: a.x + dx * t, y: a.y + dy * t))
    }

    /// Shortest distance from `point` to a polyline.
    public static func distance(from point: PagePoint, toPolyline polyline: [PagePoint]) -> Double {
        guard let first = polyline.first else { return .infinity }
        guard polyline.count > 1 else { return point.distance(to: first) }
        var best = Double.infinity
        for i in 1..<polyline.count {
            best = min(best, distance(from: point, toSegment: polyline[i - 1], polyline[i]))
            if best == 0 { break }
        }
        return best
    }

    /// True when any point of `a` lies within `tolerance` of `b`. This is a
    /// geometric test on the sampled paths: two strokes whose bounding boxes
    /// overlap but whose ink never comes close are not "touching".
    public static func polylines(_ a: [PagePoint], _ b: [PagePoint], within tolerance: Double) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        // Cheap reject first: expanded bounding boxes must overlap.
        let ra = boundingRect(a).insetBy(dx: -tolerance, dy: -tolerance)
        guard ra.intersects(boundingRect(b)) else { return false }
        for point in a where distance(from: point, toPolyline: b) <= tolerance { return true }
        for point in b where distance(from: point, toPolyline: a) <= tolerance { return true }
        return false
    }

    /// Fraction of `path`'s length whose sample points lie within `tolerance`
    /// of any polyline in `targets`. Used to require that a candidate erase
    /// gesture actually runs over existing ink rather than over blank paper.
    public static func coveredFraction(of path: [PagePoint], by targets: [[PagePoint]], tolerance: Double) -> Double {
        guard path.count > 1, !targets.isEmpty else { return 0 }
        var covered = 0.0
        var total = 0.0
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i]
            let segment = a.distance(to: b)
            guard segment > 0 else { continue }
            total += segment
            let midpoint = PagePoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if targets.contains(where: { distance(from: midpoint, toPolyline: $0) <= tolerance }) {
                covered += segment
            }
        }
        guard total > 0 else { return 0 }
        return covered / total
    }
}
