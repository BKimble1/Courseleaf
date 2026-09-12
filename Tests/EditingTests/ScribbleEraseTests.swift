import XCTest
import DocumentCore
@testable import Editing

/// Positive and negative fixtures for scribble erase. The negatives are the
/// point of the suite: a recogniser that erases handwriting is worse than no
/// recogniser at all, so every shape a student legitimately draws is asserted
/// to survive, and the assertion names the feature that rejected it.
final class ScribbleEraseTests: XCTestCase {

    /// A word of handwriting to cross out: three short strokes in a band.
    private func word(x0: Double, y: Double) -> [ScribbleEraseTarget] {
        (0..<3).map { i in
            let x = x0 + Double(i) * 36
            return ScribbleEraseTarget(index: i,
                                       polyline: StrokeFixtures.repeatedLoops(x0: x, y: y, loops: 2, width: 14, height: 18),
                                       halfWidth: 1)
        }
    }

    private func decide(_ points: [PagePoint], targets: [ScribbleEraseTarget],
                        duration: Double? = 0.45,
                        settings: ScribbleEraseSettings = ScribbleEraseSettings()) -> ScribbleEraseDecision {
        ScribbleEraseRecognizer.decide(samples: StrokeFixtures.samples(points, duration: duration),
                                       targets: targets, gestureHalfWidth: 1, settings: settings)
    }

    // MARK: Positive

    func testFivePassCrossOutOverAWordErasesExactlyThatWord() {
        let targets = word(x0: 40, y: 100)
        let scribble = StrokeFixtures.crossOut(x0: 36, x1: 150, y: 100, passes: 5)
        let decision = decide(scribble, targets: targets)
        XCTAssertTrue(decision.verdict.isErase, "features: \(decision.features)")
        XCTAssertEqual(decision.verdict.strokeIndices, [0, 1, 2])
        XCTAssertGreaterThanOrEqual(decision.features.reversals, 3)
        XCTAssertGreaterThanOrEqual(decision.features.coverage, 3)
        XCTAssertGreaterThanOrEqual(decision.features.inkOverlap, 0.5)
    }

    func testCrossOutIsRecognizedAtEveryPageRotation() {
        for degrees in [0.0, 90.0, 180.0, 270.0, 37.0] {
            let radians = degrees * Double.pi / 180
            let pivot = PagePoint(x: 90, y: 100)
            let targets = word(x0: 40, y: 100).map {
                ScribbleEraseTarget(index: $0.index,
                                    polyline: StrokeFixtures.rotated($0.polyline, by: radians, about: pivot),
                                    halfWidth: $0.halfWidth)
            }
            let scribble = StrokeFixtures.rotated(StrokeFixtures.crossOut(x0: 36, x1: 150, y: 100, passes: 5),
                                                  by: radians, about: pivot)
            let decision = decide(scribble, targets: targets)
            XCTAssertTrue(decision.verdict.isErase, "rotation \(degrees)° should not change the verdict: \(decision.features)")
        }
    }

    func testCrossOutWorksAtSmallAndLargeScale() {
        // Page space is zoom-independent, so the same gesture drawn over a small
        // word and a large one must be judged the same way.
        for factor in [0.45, 1.0, 2.5] {
            let targets = word(x0: 40, y: 100).map {
                ScribbleEraseTarget(index: $0.index, polyline: StrokeFixtures.scaled($0.polyline, by: factor),
                                    halfWidth: $0.halfWidth * factor)
            }
            let scribble = StrokeFixtures.scaled(StrokeFixtures.crossOut(x0: 36, x1: 150, y: 100, passes: 5), by: factor)
            let decision = decide(scribble, targets: targets)
            XCTAssertTrue(decision.verdict.isErase, "scale \(factor): \(decision.features)")
        }
    }

    func testOnlyStrokesActuallyCrossedAreErasedNotMerelyOverlappingBounds() {
        var targets = word(x0: 40, y: 100)
        // A bracket drawn around the margin. Its bounding box (x 20...300,
        // y 20...300) contains the whole scribble; its ink runs down the far
        // left and along the bottom and never comes near it.
        let bracket = StrokeFixtures.line(from: PagePoint(x: 20, y: 20), to: PagePoint(x: 20, y: 300))
            + StrokeFixtures.line(from: PagePoint(x: 20, y: 300), to: PagePoint(x: 300, y: 300))
        targets.append(ScribbleEraseTarget(index: 9, polyline: bracket, halfWidth: 1))
        let decision = decide(StrokeFixtures.crossOut(x0: 36, x1: 150, y: 100, passes: 5), targets: targets)
        XCTAssertEqual(decision.verdict.strokeIndices, [0, 1, 2],
                       "the bracket's bounding box overlaps; its path does not")
    }

    // MARK: Negative — things a student draws on purpose

    func testSineWaveIsNotAnErase() {
        let targets = word(x0: 40, y: 100)
        let decision = decide(StrokeFixtures.sineWave(x0: 36, x1: 200, y: 100, amplitude: 16, periods: 4),
                              targets: targets)
        assertKept(decision, "sine wave")
    }

    func testRepeatedLettersAreNotAnErase() {
        let targets = word(x0: 40, y: 100)
        let decision = decide(StrokeFixtures.repeatedLoops(x0: 36, y: 100, loops: 8), targets: targets)
        assertKept(decision, "repeated letters")
    }

    func testShadingARegionIsNotAnErase() {
        let region = PageRect(x: 36, y: 60, width: 110, height: 90)
        let targets = word(x0: 40, y: 100)
        let decision = decide(StrokeFixtures.shading(rect: region, passes: 9), targets: targets)
        assertKept(decision, "shading")
    }

    func testEngineeringHatchingIsNotAnErase() {
        let targets = word(x0: 40, y: 100)
        for (i, stroke) in StrokeFixtures.hatching(rect: PageRect(x: 36, y: 70, width: 110, height: 60)).enumerated() {
            assertKept(decide(stroke, targets: targets), "hatching line \(i)")
        }
    }

    func testZigzagDrawingIsNotAnErase() {
        let targets = word(x0: 40, y: 100)
        let decision = decide(StrokeFixtures.zigzagDrawing(x0: 36, y0: 70), targets: targets)
        assertKept(decision, "zigzag drawing")
    }

    func testWideSummationSignOverInkIsNotAnErase() {
        // The hardest negative: real reversals along its own long axis. It is
        // rejected because it is drawn deliberately, not at cross-out speed,
        // and because it retraces its span barely three times.
        let targets = word(x0: 40, y: 100)
        let decision = decide(StrokeFixtures.summationSign(x0: 36, y0: 70, width: 200, height: 60),
                              targets: targets, duration: 2.0)
        assertKept(decision, "summation sign")
    }

    func testScribblingOnBlankPaperIsNotAnErase() {
        let decision = decide(StrokeFixtures.crossOut(x0: 300, x1: 420, y: 400, passes: 5), targets: word(x0: 40, y: 100))
        assertKept(decision, "scribble away from ink")
        XCTAssertLessThan(decision.features.inkOverlap, 0.5)
    }

    func testAShortFlickIsNeverAnErase() {
        let decision = decide(StrokeFixtures.crossOut(x0: 40, x1: 50, y: 100, passes: 4), targets: word(x0: 40, y: 100))
        assertKept(decision, "short flick")
    }

    func testNoTargetsMeansNoErase() {
        let decision = decide(StrokeFixtures.crossOut(x0: 36, x1: 150, y: 100, passes: 5), targets: [])
        assertKept(decision, "no strokes on the page")
    }

    // MARK: Settings

    func testRaisingTheReversalThresholdRejectsAGestureThatOtherwisePasses() {
        var strict = ScribbleEraseSettings()
        strict.minimumReversals = 8
        let decision = decide(StrokeFixtures.crossOut(x0: 36, x1: 150, y: 100, passes: 5),
                              targets: word(x0: 40, y: 100), settings: strict)
        assertKept(decision, "raised reversal threshold")
    }

    func testMissingTimingStillDecidesWithoutSpeed() {
        let decision = decide(StrokeFixtures.crossOut(x0: 36, x1: 150, y: 100, passes: 6),
                              targets: word(x0: 40, y: 100), duration: nil)
        XCTAssertNil(decision.features.meanSpeed)
        XCTAssertTrue(decision.verdict.isErase, "six passes retrace enough to decide without timing: \(decision.features)")
    }

    private func assertKept(_ decision: ScribbleEraseDecision, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        if case .keepAsInk(let reason) = decision.verdict {
            XCTAssertFalse(reason.isEmpty, file: file, line: line)
        } else {
            XCTFail("\(what) was treated as an erase; features: \(decision.features)", file: file, line: line)
        }
    }
}
