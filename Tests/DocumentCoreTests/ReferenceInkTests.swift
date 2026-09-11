import XCTest
@testable import DocumentCore

final class ReferenceInkTests: XCTestCase {
    func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, color: RGBAColor = .black) -> ReferenceStroke {
        let n = 10
        let pts = (0...n).map { i in PagePoint(x: x0 + (x1 - x0) * Double(i) / Double(n), y: y0 + (y1 - y0) * Double(i) / Double(n)) }
        return ReferenceStroke(color: color, width: 2, points: pts)
    }

    func testEncodeDecodeRoundTrip() throws {
        let engine = ReferenceInkEngine()
        let d = ReferenceDrawing(strokes: [line(0, 0, 100, 0), line(10, 10, 10, 90, color: RGBAColor(hex: "#FF0000")!)])
        let data = try engine.encode(d)
        XCTAssertEqual(try engine.decode(data), d)
        XCTAssertThrowsError(try engine.decode(Data("junk".utf8)))
        XCTAssertEqual(data, try engine.encode(d), "encoding must be deterministic")
    }

    func testSelectionByRectAndPolygon() {
        let d = ReferenceDrawing(strokes: [line(0, 0, 100, 0), line(200, 200, 300, 200)])
        XCTAssertEqual(d.strokeIndices(intersecting: PageRect(x: 50, y: -5, width: 10, height: 10)), [0])
        XCTAssertEqual(d.strokeIndices(inside: [PagePoint(x: 190, y: 190), PagePoint(x: 310, y: 190), PagePoint(x: 310, y: 210), PagePoint(x: 190, y: 210)]), [1])
        XCTAssertEqual(d.strokeIndices(inside: [PagePoint(x: 190, y: 190), PagePoint(x: 250, y: 190), PagePoint(x: 250, y: 210), PagePoint(x: 190, y: 210)]), [], "partially covered strokes are not lasso-selected")
    }

    func testPartialEraseThenMoveAndRecolorKeepsMask() {
        // A10 at the model level: a stroke partially erased must stay erased after
        // recoloring, moving and re-serializing.
        let d = ReferenceDrawing(strokes: [line(0, 0, 100, 0)])
        let erased = d.erasing(rect: PageRect(x: 45, y: -5, width: 60, height: 10))
        XCTAssertEqual(erased.strokeCount, 1)
        let visibleXs = erased.strokes[0].visiblePagePoints.map(\.x)
        XCTAssertEqual(visibleXs.max()!, 40, accuracy: 1e-9)
        XCTAssertNotNil(erased.strokes[0].mask)

        let moved = erased.transformingStrokes([0], by: .translation(x: 500, y: 0)).recoloringStrokes([0], to: RGBAColor(hex: "#00FF00")!)
        let movedXs = moved.strokes[0].visiblePagePoints.map(\.x)
        XCTAssertEqual(movedXs.max()!, 540, accuracy: 1e-9, "erased portion must not reappear after moving")
        XCTAssertEqual(moved.strokes[0].color, RGBAColor(hex: "#00FF00")!)
        XCTAssertEqual(moved.strokes[0].mask, erased.strokes[0].mask, "recolor keeps the mask")

        let engine = ReferenceInkEngine()
        let reopened = try! engine.decode(try! engine.encode(moved))
        XCTAssertEqual(reopened.strokes[0].visiblePagePoints.map(\.x).max()!, 540, accuracy: 1e-9)
        XCTAssertEqual(reopened.bounds.maxX, 541, accuracy: 1e-9)

        // Fully erased strokes are dropped.
        XCTAssertTrue(d.erasing(rect: PageRect(x: -1, y: -1, width: 102, height: 2)).isEmpty)
    }

    func testCopyPasteAndRemove() {
        let d = ReferenceDrawing(strokes: [line(0, 0, 1, 0), line(2, 0, 3, 0), line(4, 0, 5, 0)])
        let copied = d.extractingStrokes([2, 0])
        XCTAssertEqual(copied.strokes.map { $0.points[0].x }, [4, 0])
        let removed = d.removingStrokes([1])
        XCTAssertEqual(removed.strokes.map { $0.points[0].x }, [0, 4])
        XCTAssertEqual(removed.appending(copied).strokeCount, 4)
        XCTAssertEqual(ReferenceDrawing().bounds, .zero)
    }

    func testPolygonContainment() {
        let square = [PagePoint(x: 0, y: 0), PagePoint(x: 10, y: 0), PagePoint(x: 10, y: 10), PagePoint(x: 0, y: 10)]
        XCTAssertTrue(Polygon.contains(square, PagePoint(x: 5, y: 5)))
        XCTAssertTrue(Polygon.contains(square, PagePoint(x: 10, y: 5)), "edge counts as inside")
        XCTAssertFalse(Polygon.contains(square, PagePoint(x: 11, y: 5)))
        XCTAssertFalse(Polygon.contains([PagePoint(x: 0, y: 0)], PagePoint(x: 0, y: 0)))
    }
}
