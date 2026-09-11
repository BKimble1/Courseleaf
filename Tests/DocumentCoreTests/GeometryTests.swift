import XCTest
@testable import DocumentCore

final class GeometryTests: XCTestCase {
    func testTransformConcatenationOrder() {
        // Scale then translate: (1,1) -> (2,2) -> (12,22)
        let t = PageTransform.scale(2).concatenating(.translation(x: 10, y: 20))
        let p = t.apply(PagePoint(x: 1, y: 1))
        XCTAssertEqual(p.x, 12, accuracy: 1e-12); XCTAssertEqual(p.y, 22, accuracy: 1e-12)
    }

    func testInverseRoundTrip() {
        let t = PageTransform.rotation(radians: 0.7, about: PagePoint(x: 30, y: 40)).concatenating(.scale(x: 1.5, y: 0.5)).concatenating(.translation(x: -3, y: 9))
        let inv = try! XCTUnwrap(t.inverted())
        let p = PagePoint(x: 123.4, y: -56.7)
        let back = inv.apply(t.apply(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9); XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        XCTAssertTrue(t.concatenating(inv).isApproximatelyEqual(to: .identity))
    }

    func testSingularTransformHasNoInverse() {
        XCTAssertNil(PageTransform.scale(x: 0, y: 1).inverted())
    }

    func testRotationAboutCenterKeepsCenter() {
        let r = PageRect(x: 10, y: 10, width: 100, height: 50)
        let t = PageTransform.rotation(radians: .pi / 2, about: r.center)
        let c = t.apply(r.center)
        XCTAssertEqual(c.x, r.center.x, accuracy: 1e-9); XCTAssertEqual(c.y, r.center.y, accuracy: 1e-9)
        let b = r.applying(t)
        XCTAssertEqual(b.width, 50, accuracy: 1e-9); XCTAssertEqual(b.height, 100, accuracy: 1e-9)
    }

    func testRectOperations() {
        let a = PageRect(x: 0, y: 0, width: 10, height: 10)
        let b = PageRect(x: 5, y: 5, width: 10, height: 10)
        XCTAssertEqual(a.intersection(b), PageRect(x: 5, y: 5, width: 5, height: 5))
        XCTAssertEqual(a.union(b), PageRect(x: 0, y: 0, width: 15, height: 15))
        XCTAssertNil(a.intersection(PageRect(x: 20, y: 20, width: 1, height: 1)))
        XCTAssertTrue(a.contains(PagePoint(x: 10, y: 10)))
        XCTAssertEqual(PageRect(x: 10, y: 10, width: -4, height: -4).standardized, PageRect(x: 6, y: 6, width: 4, height: 4))
        XCTAssertEqual(a.denormalizing(PageRect(x: 0.5, y: 0.5, width: 0.5, height: 0.25)), PageRect(x: 5, y: 5, width: 5, height: 2.5))
    }

    func testPageRotationNormalization() {
        XCTAssertEqual(PageRotation(degrees: -90), .degrees270)
        XCTAssertEqual(PageRotation(degrees: 450), .degrees90)
        XCTAssertNil(PageRotation(degrees: 45))
        XCTAssertEqual(PageRotation.degrees270.rotated(by: .degrees180), .degrees90)
        XCTAssertTrue(PageRotation.degrees90.swapsWidthAndHeight)
    }

    func testColorHex() {
        let c = RGBAColor(hex: "#1A2B3C")!
        XCTAssertEqual(c.hexString, "#1A2B3CFF")
        XCTAssertEqual(RGBAColor(hex: "1A2B3C80")!.alpha, 128.0 / 255, accuracy: 1e-9)
        XCTAssertNil(RGBAColor(hex: "#12"))
    }

    func testObjectTransformMapsUnitSquareToFrame() {
        let o = CanvasObject(frame: PageRect(x: 100, y: 200, width: 50, height: 20), content: .text(TextContent(text: "x")), createdAt: Date(timeIntervalSince1970: 0))
        let p = o.transform.apply(PagePoint(x: 1, y: 1))
        XCTAssertEqual(p.x, 150, accuracy: 1e-9); XCTAssertEqual(p.y, 220, accuracy: 1e-9)
        XCTAssertEqual(o.bounds, o.frame)
        var rotated = o; rotated.rotation = .pi / 2
        XCTAssertEqual(rotated.bounds.width, 20, accuracy: 1e-9); XCTAssertEqual(rotated.bounds.height, 50, accuracy: 1e-9)
        XCTAssertEqual(rotated.bounds.center.x, 125, accuracy: 1e-9)
    }
}
