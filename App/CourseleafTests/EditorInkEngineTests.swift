import XCTest
import UIKit
import CoreGraphics
import PencilKit
import DocumentCore
@testable import Courseleaf

// `PencilKitInkEngine` semantics the editor depends on (docs/ARCHITECTURE.md §5,
// acceptance A10): transforming and recoloring a stroke must leave its erase
// mask exactly as it was, so partially erased ink never reappears, and the
// lasso must pick up the strokes a student actually enclosed.
final class EditorInkEngineTests: XCTestCase {

    private let creationDate = Date(timeIntervalSince1970: 1_757_600_000)

    private func makeStroke(from start: CGPoint, to end: CGPoint,
                            color: UIColor = .black,
                            mask: UIBezierPath? = nil,
                            transform: CGAffineTransform = .identity,
                            inkType: PKInk.InkType = .pen) -> PKStroke {
        var points: [PKStrokePoint] = []
        let steps = 10
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let location = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            points.append(PKStrokePoint(location: location, timeOffset: TimeInterval(i) * 0.01,
                                        size: CGSize(width: 4, height: 4), opacity: 1, force: 1,
                                        azimuth: 0, altitude: .pi / 2))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: creationDate)
        return PKStroke(ink: PKInk(inkType, color: color), path: path, transform: transform, mask: mask, randomSeed: 7)
    }

    private func assertSameBoundingBox(_ lhs: UIBezierPath, _ rhs: UIBezierPath,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let a = lhs.cgPath.boundingBoxOfPath
        let b = rhs.cgPath.boundingBoxOfPath
        XCTAssertEqual(a.minX, b.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: 0.001, file: file, line: line)
    }

    private func assertSameTransform(_ a: CGAffineTransform, _ b: CGAffineTransform,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.a, b.a, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.b, b.b, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.c, b.c, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.d, b.d, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.tx, b.tx, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.ty, b.ty, accuracy: 1e-9, file: file, line: line)
    }

    // MARK: Transform

    func testTransformingAStrokeConcatenatesTheTransformAndKeepsTheEraseMask() throws {
        let mask = UIBezierPath(rect: CGRect(x: 0, y: 10, width: 50, height: 20))
        let drawing = PencilKitDrawing(strokes: [makeStroke(from: CGPoint(x: 0, y: 20), to: CGPoint(x: 100, y: 20), mask: mask)])
        // Compare against the stroke as the drawing stores it, not the one just built.
        let stored = try XCTUnwrap(drawing.strokes.first)
        let storedMask = try XCTUnwrap(stored.mask)

        let move = PageTransform.translation(x: 30, y: -12)
        let moved = drawing.transformingStrokes([0], by: move)
        let result = try XCTUnwrap(moved.strokes.first)

        assertSameTransform(result.transform, stored.transform.concatenating(CGAffineTransform(move)))

        // The mask lives in the stroke path's own space and must be untouched:
        // the transform moves path and mask together.
        let resultMask = try XCTUnwrap(result.mask)
        assertSameBoundingBox(resultMask, storedMask)
        for point in [CGPoint(x: 5, y: 20), CGPoint(x: 25, y: 15), CGPoint(x: 80, y: 20), CGPoint(x: 25, y: 90)] {
            XCTAssertEqual(resultMask.contains(point), storedMask.contains(point), "mask changed at \(point)")
        }

        // The visible ink really did move by the transform.
        let before = try XCTUnwrap(drawing.bounds(ofStrokes: [0]))
        let after = try XCTUnwrap(moved.bounds(ofStrokes: [0]))
        XCTAssertEqual(after.minX - before.minX, 30, accuracy: 0.5)
        XCTAssertEqual(after.minY - before.minY, -12, accuracy: 0.5)
    }

    func testTransformingOneStrokeLeavesTheOthersAlone() throws {
        let a = makeStroke(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 40, y: 0))
        let b = makeStroke(from: CGPoint(x: 0, y: 60), to: CGPoint(x: 40, y: 60))
        let drawing = PencilKitDrawing(strokes: [a, b])
        let storedFirst = try XCTUnwrap(drawing.strokes.first)
        let storedSecond = drawing.strokes[1]
        let moved = drawing.transformingStrokes([1], by: .translation(x: 100, y: 0))
        assertSameTransform(try XCTUnwrap(moved.strokes.first).transform, storedFirst.transform)
        assertSameTransform(moved.strokes[1].transform, storedSecond.transform.concatenating(CGAffineTransform(translationX: 100, y: 0)))
    }

    // MARK: Recolor

    func testRecoloringKeepsPathTransformAndMaskAndOnlyChangesTheInkColour() throws {
        let mask = UIBezierPath(rect: CGRect(x: 10, y: 12, width: 30, height: 16))
        let transform = CGAffineTransform(translationX: 7, y: -3).rotated(by: 0.4)
        let drawing = PencilKitDrawing(strokes: [makeStroke(from: CGPoint(x: 0, y: 20), to: CGPoint(x: 80, y: 20),
                                                            color: .black, mask: mask, transform: transform)])
        let original = try XCTUnwrap(drawing.strokes.first)
        let originalMask = try XCTUnwrap(original.mask)

        let red = RGBAColor(hex: "#D0312D")!
        let recolored = drawing.recoloringStrokes([0], to: red)
        let result = try XCTUnwrap(recolored.strokes.first)

        assertSameTransform(result.transform, original.transform)
        XCTAssertEqual(result.path.count, original.path.count)
        for index in 0..<result.path.count {
            XCTAssertEqual(result.path[index].location.x, original.path[index].location.x, accuracy: 1e-6)
            XCTAssertEqual(result.path[index].location.y, original.path[index].location.y, accuracy: 1e-6)
            XCTAssertEqual(result.path[index].size.width, original.path[index].size.width, accuracy: 1e-6)
            XCTAssertEqual(result.path[index].opacity, original.path[index].opacity, accuracy: 1e-6)
        }
        let resultMask = try XCTUnwrap(result.mask)
        assertSameBoundingBox(resultMask, originalMask)
        for point in [CGPoint(x: 15, y: 20), CGPoint(x: 60, y: 20), CGPoint(x: 15, y: 80)] {
            XCTAssertEqual(resultMask.contains(point), originalMask.contains(point), "mask changed at \(point)")
        }

        XCTAssertEqual(result.ink.inkType, original.ink.inkType)
        let expected = PKInk(.pen, color: UIColor(red)).color.rgbaColor
        let actual = result.ink.color.rgbaColor
        XCTAssertEqual(actual.red, expected.red, accuracy: 0.005)
        XCTAssertEqual(actual.green, expected.green, accuracy: 0.005)
        XCTAssertEqual(actual.blue, expected.blue, accuracy: 0.005)
        XCTAssertNotEqual(actual.hexString, original.ink.color.rgbaColor.hexString)
    }

    // MARK: Hit testing

    func testStrokeIndicesIntersectingSelectsOnlyStrokesWithVisibleInkInTheRect() {
        let inside = makeStroke(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 10))
        let faraway = makeStroke(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 260, y: 200))
        let crossing = makeStroke(from: CGPoint(x: 55, y: 12), to: CGPoint(x: 180, y: 120))
        // Only the far right of this stroke is still visible after erasing.
        let erasedInsideTheRect = makeStroke(from: CGPoint(x: 10, y: 40), to: CGPoint(x: 300, y: 40),
                                             mask: UIBezierPath(rect: CGRect(x: 200, y: 20, width: 120, height: 40)))
        let drawing = PencilKitDrawing(strokes: [inside, faraway, crossing, erasedInsideTheRect])

        let hits = Set(drawing.strokeIndices(intersecting: PageRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertTrue(hits.contains(0))
        XCTAssertFalse(hits.contains(1))
        XCTAssertTrue(hits.contains(2))
        XCTAssertFalse(hits.contains(3), "erased ink must not be selectable")
    }

    func testStrokeIndicesInsidePolygonRequiresTheWholeStroke() {
        let contained = makeStroke(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40))
        let crossing = makeStroke(from: CGPoint(x: 55, y: 12), to: CGPoint(x: 180, y: 120))
        let outside = makeStroke(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 260, y: 200))
        let drawing = PencilKitDrawing(strokes: [contained, crossing, outside])

        let square = [PagePoint(x: 0, y: 0), PagePoint(x: 100, y: 0), PagePoint(x: 100, y: 100), PagePoint(x: 0, y: 100)]
        XCTAssertEqual(drawing.strokeIndices(inside: square), [0])
        XCTAssertEqual(drawing.strokeIndices(inside: []), [])
    }

    // MARK: Encode / decode

    func testEngineRoundTripsADrawingThroughItsBlob() throws {
        let engine = PencilKitInkEngine()
        XCTAssertEqual(engine.identifier, .pencilKit)
        let mask = UIBezierPath(rect: CGRect(x: 0, y: 10, width: 40, height: 20))
        let drawing = PencilKitDrawing(strokes: [makeStroke(from: CGPoint(x: 0, y: 20), to: CGPoint(x: 90, y: 20), mask: mask)])
        let data = try engine.encode(drawing)
        let decoded = try engine.decode(data)
        XCTAssertEqual(decoded.strokeCount, 1)
        XCTAssertEqual(decoded.bounds.minX, drawing.bounds.minX, accuracy: 0.5)
        XCTAssertThrowsError(try engine.decode(Data("not a drawing".utf8)))
    }
}
