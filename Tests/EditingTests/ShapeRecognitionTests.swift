import XCTest
import DocumentCore
@testable import Editing

/// Geometry for freehand shape correction. Every assertion is on the corrected
/// shape's page-space coordinates, because those are what gets drawn, exported
/// and hit-tested later — not on a confidence number alone.
final class ShapeRecognitionTests: XCTestCase {

    private func recognize(_ points: [PagePoint],
                           _ settings: ShapeCorrectionSettings = ShapeCorrectionSettings()) -> ShapeRecognition? {
        ShapeRecognizer.recognize(points, settings: settings)
    }

    private func assertClose(_ a: Double, _ b: Double, _ tolerance: Double, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: tolerance, what, file: file, line: line)
    }

    // MARK: Lines

    func testDiagonalLineIsStraightenedButKeepsItsAngle() {
        // 30 degrees below horizontal: a diagonal must never be snapped onto an axis.
        let from = PagePoint(x: 100, y: 100)
        let to = PagePoint(x: 100 + 200 * cos(.pi / 6), y: 100 + 200 * sin(.pi / 6))
        var points = StrokeFixtures.line(from: from, to: to, samples: 60)
        points = points.enumerated().map { i, p in
            PagePoint(x: p.x, y: p.y + 1.2 * sin(Double(i) / 6))   // hand wobble
        }
        guard case .line(let a, let b)? = recognize(points)?.shape else {
            return XCTFail("expected a line, got \(String(describing: recognize(points)?.shape))")
        }
        let angle = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
        assertClose(angle, 30, 3, "a 30° line stays a 30° line")
        assertClose(a.distance(to: b), 200, 8, "length is preserved")
    }

    func testNearlyHorizontalLineSnapsToTheAxisWhenSnappingIsOn() {
        let from = PagePoint(x: 60, y: 200)
        let to = PagePoint(x: 260, y: 200 + 200 * tan(2 * .pi / 180))    // 2° off horizontal
        guard case .line(let a, let b)? = recognize(StrokeFixtures.line(from: from, to: to, samples: 50))?.shape else {
            return XCTFail("expected a line")
        }
        assertClose(a.y, b.y, 0.001, "snapped flat")
    }

    func testTenDegreeLineIsNotSnappedWithTheDefaultTolerance() {
        let from = PagePoint(x: 60, y: 200)
        let to = PagePoint(x: 260, y: 200 + 200 * tan(10 * .pi / 180))
        guard case .line(let a, let b)? = recognize(StrokeFixtures.line(from: from, to: to, samples: 50))?.shape else {
            return XCTFail("expected a line")
        }
        XCTAssertGreaterThan(abs(b.y - a.y), 20, "10° is a deliberate slope, not a wobbly horizontal")
    }

    func testSnappingCanBeTurnedOff() {
        var settings = ShapeCorrectionSettings()
        settings.snapsLinesToAxis = false
        let from = PagePoint(x: 60, y: 200)
        let to = PagePoint(x: 260, y: 200 + 200 * tan(2 * .pi / 180))
        guard case .line(let a, let b)? = recognize(StrokeFixtures.line(from: from, to: to, samples: 50), settings)?.shape else {
            return XCTFail("expected a line")
        }
        XCTAssertGreaterThan(abs(b.y - a.y), 3, "without snapping the drawn slope is kept")
    }

    func testLineDirectionFollowsTheStroke() {
        let points = StrokeFixtures.line(from: PagePoint(x: 300, y: 100), to: PagePoint(x: 100, y: 100), samples: 40)
        guard case .line(let a, let b)? = recognize(points)?.shape else { return XCTFail("expected a line") }
        XCTAssertGreaterThan(a.x, b.x, "the stroke was drawn right to left")
    }

    // MARK: Circles and ellipses

    func testHandDrawnCircleBecomesACircle() {
        let recognition = recognize(StrokeFixtures.circle(center: PagePoint(x: 200, y: 200), radius: 40))
        guard case .ellipse(let center, let ra, let rb, _)? = recognition?.shape else {
            return XCTFail("expected an ellipse, got \(String(describing: recognition?.shape))")
        }
        assertClose(center.x, 200, 4, "centre x")
        assertClose(center.y, 200, 4, "centre y")
        assertClose(ra, 40, 5, "radius along")
        assertClose(rb, 40, 5, "radius across")
        assertClose(ra, rb, 0.001, "equal radii are snapped to a circle")
    }

    func testEllipseKeepsItsTwoRadii() {
        var settings = ShapeCorrectionSettings()
        settings.snapsEqualSides = false
        let squashed = StrokeFixtures.circle(center: PagePoint(x: 0, y: 0), radius: 60, wobble: 1)
            .map { PagePoint(x: 200 + $0.x, y: 200 + $0.y * 0.5) }
        guard case .ellipse(_, let ra, let rb, _)? = recognize(squashed, settings)?.shape else {
            return XCTFail("expected an ellipse")
        }
        assertClose(ra, 60, 6, "long radius")
        assertClose(rb, 30, 6, "short radius")
    }

    // MARK: Rectangles

    func testHandDrawnRectangleBecomesARectangle() {
        let rect = PageRect(x: 60, y: 80, width: 160, height: 100)
        let recognition = recognize(StrokeFixtures.rectangle(rect))
        guard case .rectangle(let corners)? = recognition?.shape else {
            return XCTFail("expected a rectangle, got \(String(describing: recognition?.shape))")
        }
        XCTAssertEqual(corners.count, 4)
        let bounds = PageRect.bounding(corners) ?? .zero
        assertClose(bounds.minX, rect.minX, 4, "left")
        assertClose(bounds.minY, rect.minY, 4, "top")
        assertClose(bounds.width, rect.width, 6, "width")
        assertClose(bounds.height, rect.height, 6, "height")
    }

    func testNearSquareIsSnappedToASquare() {
        let recognition = recognize(StrokeFixtures.rectangle(PageRect(x: 40, y: 40, width: 100, height: 106)))
        guard case .rectangle(let corners)? = recognition?.shape else { return XCTFail("expected a rectangle") }
        let bounds = PageRect.bounding(corners) ?? .zero
        assertClose(bounds.width, bounds.height, 0.5, "a near-square is squared up")
    }

    func testRotatedRectangleKeepsItsRotation() {
        let base = StrokeFixtures.rectangle(PageRect(x: 60, y: 60, width: 160, height: 90))
        let pivot = PagePoint(x: 140, y: 105)
        let turned = StrokeFixtures.rotated(base, by: 25 * .pi / 180, about: pivot)
        guard case .rectangle(let corners)? = recognize(turned)?.shape else { return XCTFail("expected a rectangle") }
        let edge = atan2(corners[1].y - corners[0].y, corners[1].x - corners[0].x) * 180 / .pi
        assertClose(edge, 25, 5, "the long edge keeps the angle it was drawn at")
    }

    func testSmallAndLargeSquaresBehaveTheSame() {
        for size in [26.0, 120.0, 460.0] {
            let recognition = recognize(StrokeFixtures.rectangle(PageRect(x: 10, y: 10, width: size, height: size),
                                                                 wobble: size * 0.012))
            guard case .rectangle(let corners)? = recognition?.shape else {
                return XCTFail("size \(size) was not recognised as a rectangle")
            }
            let bounds = PageRect.bounding(corners) ?? .zero
            assertClose(bounds.width, size, size * 0.12, "width at size \(size)")
        }
    }

    // MARK: Refusals

    func testAScribbleIsNotAShape() {
        XCTAssertNil(recognize(StrokeFixtures.crossOut(x0: 40, x1: 160, y: 100, passes: 5)))
    }

    func testASineWaveIsNotAShape() {
        XCTAssertNil(recognize(StrokeFixtures.sineWave(x0: 40, x1: 240, y: 100, amplitude: 22, periods: 3)))
    }

    func testHandwritingLoopsAreNotAShape() {
        XCTAssertNil(recognize(StrokeFixtures.repeatedLoops(x0: 40, y: 100, loops: 6)))
    }

    func testATinyStrokeIsNeverCorrected() {
        XCTAssertNil(recognize(StrokeFixtures.line(from: PagePoint(x: 10, y: 10), to: PagePoint(x: 21, y: 14))),
                     "a 12-point flick is a tick, not a line")
    }

    func testRaisingTheConfidenceGateRefusesAWobblyShape() {
        var strict = ShapeCorrectionSettings()
        strict.minimumConfidence = 0.99
        XCTAssertNil(recognize(StrokeFixtures.circle(center: PagePoint(x: 200, y: 200), radius: 40), strict))
    }

    func testDisablingAKindFallsBackToNothing() {
        var settings = ShapeCorrectionSettings()
        settings.recognisesEllipses = false
        settings.recognisesRectangles = false
        XCTAssertNil(recognize(StrokeFixtures.circle(center: PagePoint(x: 200, y: 200), radius: 40), settings))
    }

    // MARK: Outline

    func testEllipseOutlineIsClosedAndOnTheCurve() {
        let shape = RecognizedShape.ellipse(center: PagePoint(x: 100, y: 100), radiusAlong: 50, radiusAcross: 25, rotation: 0)
        let outline = shape.polyline()
        XCTAssertEqual(outline.first, outline.last, "closed")
        for point in outline {
            let u = (point.x - 100) / 50, v = (point.y - 100) / 25
            assertClose((u * u + v * v).squareRoot(), 1, 0.001, "every outline point sits on the ellipse")
        }
    }

    func testRectangleOutlineRepeatsItsFirstCorner() {
        let corners = [PagePoint(x: 0, y: 0), PagePoint(x: 10, y: 0), PagePoint(x: 10, y: 5), PagePoint(x: 0, y: 5)]
        XCTAssertEqual(RecognizedShape.rectangle(corners: corners).polyline().count, 5)
    }
}
