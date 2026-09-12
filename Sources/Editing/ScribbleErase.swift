import Foundation
import DocumentCore

// Scribble erase: crossing existing handwriting out with the writing tool
// removes it, without switching to the eraser.
//
// This is *not* Apple's Scribble (handwriting-to-text). It is also not machine
// learning: it is a geometric heuristic over the candidate stroke's own shape
// and its overlap with the ink already on the page, with every threshold named
// and testable (`Tests/EditingTests/ScribbleEraseTests.swift`). When the
// evidence is not decisive the gesture is rejected and the input stays as
// ordinary ink, because writing that is wrongly erased costs a student far
// more than an erase that has to be repeated.
//
// The features, and why each one is here:
//
//  * significant reversals along the stroke's own principal axis. Crossing out
//    is back-and-forth over the same span. A sine wave, a row of "e"s and
//    engineering hatching all advance monotonically along that axis, so they
//    score zero however wiggly they look across it.
//  * coverage: path length divided by the span it covers. Four passes over a
//    word gives roughly four; one pass of decorated handwriting gives one.
//  * elongation: a cross-out is a band. Shading fills an area, so its span
//    across the axis approaches its span along it.
//  * ink overlap: the gesture has to run over ink that is actually there.
//    Scribbling on blank paper is a drawing, not a command.
//  * speed, when the samples carry timing: a deliberate cross-out is fast.
//    Used only to break the tie at the minimum reversal count, and skipped
//    entirely when the platform gave us no timestamps.

/// One sampled point of a candidate gesture. `timeOffset` is seconds from the
/// first sample; nil everywhere means the platform gave no timing.
public struct StrokeSample: Hashable, Sendable {
    public var location: PagePoint
    public var timeOffset: Double?
    public init(location: PagePoint, timeOffset: Double? = nil) {
        self.location = location
        self.timeOffset = timeOffset
    }
}

/// Thresholds for `ScribbleEraseRecognizer`. Defaults are the shipping values;
/// tests vary them to show which feature each rejection depends on.
public struct ScribbleEraseSettings: Hashable, Sendable {
    /// Minimum number of genuine direction reversals along the principal axis.
    public var minimumReversals: Int = 3
    /// A reversal only counts when the run before it covered this fraction of the span.
    public var minimumRunFraction: Double = 0.45
    /// Path length divided by the span along the principal axis.
    public var minimumCoverage: Double = 3.0
    /// Span along the principal axis divided by the span across it.
    public var minimumElongation: Double = 1.6
    /// Fraction of the gesture that must run within `overlapTolerance` of existing ink.
    public var minimumInkOverlap: Double = 0.5
    /// How close the gesture has to pass to count as running over a stroke, in page points.
    /// Scaled by the tool widths at the call site.
    public var overlapTolerance: Double = 6
    /// Gestures shorter than this are never erases (a flick, a dot, a short accent).
    public var minimumPathLength: Double = 24
    /// At exactly `minimumReversals`, also require this speed (page points per
    /// second) or `fastCoverage`. Ignored when the samples carry no timing.
    public var minimumSpeed: Double = 150
    /// Coverage that stands in for speed when timing is unavailable or slow.
    public var fastCoverage: Double = 4.0
    public init() {}
}

/// The measurements the decision is made from. Returned with every verdict so a
/// failing test says which feature was out of range, not just "false".
public struct ScribbleEraseFeatures: Hashable, Sendable {
    public var pathLength: Double = 0
    public var axisExtent: Double = 0
    public var crossExtent: Double = 0
    public var reversals: Int = 0
    public var coverage: Double = 0
    public var elongation: Double = 0
    public var inkOverlap: Double = 0
    public var crossedStrokeCount: Int = 0
    public var meanSpeed: Double?
    public init() {}
}

public enum ScribbleEraseVerdict: Hashable, Sendable {
    /// The gesture is a cross-out; these stroke indices are under it.
    case erase(strokeIndices: [Int])
    /// Keep the input as ordinary ink. `reason` names the first failing feature.
    case keepAsInk(reason: String)

    public var isErase: Bool { if case .erase = self { return true }; return false }
    public var strokeIndices: [Int] { if case .erase(let i) = self { return i }; return [] }
}

public struct ScribbleEraseDecision: Hashable, Sendable {
    public var verdict: ScribbleEraseVerdict
    public var features: ScribbleEraseFeatures
    public init(verdict: ScribbleEraseVerdict, features: ScribbleEraseFeatures) {
        self.verdict = verdict
        self.features = features
    }
}

/// A stroke already on the page, as the recogniser needs to see it: its visible
/// sampled path in page space and the index that addresses it in the drawing.
public struct ScribbleEraseTarget: Hashable, Sendable {
    public var index: Int
    public var polyline: [PagePoint]
    /// Half the stroke's drawn width, added to the overlap tolerance so a thick
    /// highlighter counts as crossed when the gesture runs over its body.
    public var halfWidth: Double
    public init(index: Int, polyline: [PagePoint], halfWidth: Double = 0) {
        self.index = index
        self.polyline = polyline
        self.halfWidth = halfWidth
    }
}

public enum ScribbleEraseRecognizer {

    /// Decides whether `samples` is a deliberate cross-out of `targets`.
    ///
    /// - Parameters:
    ///   - samples: the candidate gesture in page space, in order.
    ///   - targets: strokes already on the page that the gesture may be erasing.
    ///     The caller filters out anything that is not erasable ink; PDF
    ///     backgrounds, images, text boxes and shapes are objects, never targets.
    ///   - gestureHalfWidth: half the candidate tool's width, in page points.
    ///   - settings: thresholds.
    public static func decide(samples: [StrokeSample],
                              targets: [ScribbleEraseTarget],
                              gestureHalfWidth: Double = 1,
                              settings: ScribbleEraseSettings = ScribbleEraseSettings()) -> ScribbleEraseDecision {
        var features = ScribbleEraseFeatures()
        let raw = samples.map(\.location)
        guard raw.count >= 4 else {
            return ScribbleEraseDecision(verdict: .keepAsInk(reason: "too few samples"), features: features)
        }
        // Resampling makes every measure independent of the device's sample rate.
        let points = StrokeGeometry.resampled(raw, spacing: 1.5)
        features.pathLength = StrokeGeometry.pathLength(points)
        guard features.pathLength >= settings.minimumPathLength else {
            return ScribbleEraseDecision(verdict: .keepAsInk(reason: "too short"), features: features)
        }

        let axes = StrokeGeometry.principalAxis(points)
        let along = StrokeGeometry.projections(points, onto: axes.along)
        let across = StrokeGeometry.projections(points, onto: axes.across)
        features.axisExtent = StrokeGeometry.extent(along)
        features.crossExtent = StrokeGeometry.extent(across)
        guard features.axisExtent > 1e-6 else {
            return ScribbleEraseDecision(verdict: .keepAsInk(reason: "no extent"), features: features)
        }
        features.coverage = features.pathLength / features.axisExtent
        features.elongation = features.axisExtent / max(features.crossExtent, 1e-6)
        features.reversals = StrokeGeometry.significantReversals(
            along, minimumRun: features.axisExtent * settings.minimumRunFraction)

        if let last = samples.last?.timeOffset, let first = samples.first?.timeOffset, last > first {
            features.meanSpeed = features.pathLength / (last - first)
        }

        guard features.reversals >= settings.minimumReversals else {
            return ScribbleEraseDecision(verdict: .keepAsInk(reason: "not enough reversals"), features: features)
        }
        guard features.coverage >= settings.minimumCoverage else {
            return ScribbleEraseDecision(verdict: .keepAsInk(reason: "path does not retrace"), features: features)
        }
        guard features.elongation >= settings.minimumElongation else {
            return ScribbleEraseDecision(verdict: .keepAsInk(reason: "fills an area rather than crossing a band"), features: features)
        }
        // At the minimum reversal count the shape alone is not decisive, so ask
        // for speed or for more retracing before touching the page.
        if features.reversals == settings.minimumReversals {
            let fastEnough = (features.meanSpeed ?? 0) >= settings.minimumSpeed
            if !fastEnough && features.coverage < settings.fastCoverage {
                return ScribbleEraseDecision(verdict: .keepAsInk(reason: "marginal gesture, not decisive"), features: features)
            }
        }

        let polylines = targets.map(\.polyline)
        features.inkOverlap = StrokeGeometry.coveredFraction(
            of: points, by: polylines, tolerance: settings.overlapTolerance + gestureHalfWidth)
        guard features.inkOverlap >= settings.minimumInkOverlap else {
            return ScribbleEraseDecision(verdict: .keepAsInk(reason: "not over existing ink"), features: features)
        }

        // Geometric hit test per stroke: a stroke is erased because the gesture
        // ran over its path, never because their bounding rectangles overlap.
        let hit = targets.filter { target in
            StrokeGeometry.polylines(points, target.polyline,
                                     within: settings.overlapTolerance + gestureHalfWidth + target.halfWidth)
        }
        features.crossedStrokeCount = hit.count
        guard !hit.isEmpty else {
            return ScribbleEraseDecision(verdict: .keepAsInk(reason: "crossed no stroke"), features: features)
        }
        return ScribbleEraseDecision(verdict: .erase(strokeIndices: hit.map(\.index).sorted()), features: features)
    }
}
