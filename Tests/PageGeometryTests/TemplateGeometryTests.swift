import XCTest
import DocumentCore
@testable import PageGeometry

final class TemplateGeometryTests: XCTestCase {
    func lines(_ p: [TemplatePrimitive]) -> [TemplatePrimitive] { p.filter { if case .line = $0 { return true } else { return false } } }
    func dots(_ p: [TemplatePrimitive]) -> [TemplatePrimitive] { p.filter { if case .dot = $0 { return true } else { return false } } }

    func assertInsidePage(_ prims: [TemplatePrimitive], size: PageSize, line: UInt = #line) {
        let page = PageRect(origin: .zero, size: size)
        for p in prims {
            XCTAssertTrue(page.contains(p.bounds.standardized), "primitive outside page: \(p)", line: line)
            if case .line(let a, let b, let w, _) = p {
                XCTAssertTrue(page.contains(a) && page.contains(b), "line endpoints outside page: \(p)", line: line)
                XCTAssertGreaterThan(w, 0, line: line)
                // No line on the page edge itself.
                if a.x == b.x { XCTAssertTrue(a.x > 0 && a.x < size.width, "edge line \(p)", line: line) }
                if a.y == b.y { XCTAssertTrue(a.y > 0 && a.y < size.height, "edge line \(p)", line: line) }
            }
        }
    }

    func testEveryKindStartsWithPaperRectAndStaysInsideBounds() {
        for kind in PaperKind.allCases {
            let t = PaperTemplate.preset(kind)
            for size in [PageSize.letter, .a4, PageSize.letter.swapped, PageSize(width: 200, height: 100)] {
                let prims = TemplateGeometry.primitives(for: t, size: size)
                guard case .rect(let r, let fill) = prims[0] else { return XCTFail("first primitive must be the paper rect") }
                XCTAssertEqual(r, PageRect(origin: .zero, size: size)); XCTAssertEqual(fill, t.paperColor)
                assertInsidePage(prims, size: size)
                if kind == .blank { XCTAssertEqual(prims.count, 1) } else { XCTAssertGreaterThan(prims.count, 1, "\(kind)") }
            }
        }
    }

    func testLinedRulesStartAtTopMarginEverySpacingAndScaleWithHeight() {
        let t = PaperTemplate.lined // spacing 20, topMargin 72, no margin rule
        let letter = TemplateGeometry.primitives(for: t, size: .letter)
        let rules = lines(letter)
        // y = 72, 92, ..., < 792 → k = 0...35 → 36 rules.
        XCTAssertEqual(rules.count, 36)
        guard case .line(let a, let b, _, let color) = rules[0] else { return XCTFail() }
        XCTAssertEqual(a, PagePoint(x: 0, y: 72)); XCTAssertEqual(b, PagePoint(x: 612, y: 72)); XCTAssertEqual(color, t.lineColor)
        // Double the height: (1584 − 72) / 20 → k = 0...75 → 76 rules.
        let tall = lines(TemplateGeometry.primitives(for: t, size: PageSize(width: 612, height: 1584)))
        XCTAssertEqual(tall.count, 76)
        // Width does not change the count, only the rule length.
        let wide = lines(TemplateGeometry.primitives(for: t, size: PageSize(width: 1224, height: 792)))
        XCTAssertEqual(wide.count, 36)
        guard case .line(_, let end, _, _) = wide[0] else { return XCTFail() }
        XCTAssertEqual(end.x, 1224)
        // A left margin adds one vertical rule in the margin colour.
        var margin = t; margin.leftMargin = 60
        let withMargin = lines(TemplateGeometry.primitives(for: margin, size: .letter))
        XCTAssertEqual(withMargin.count, 37)
        let vertical = withMargin.filter { if case .line(let a, let b, _, _) = $0 { return a.x == b.x } else { return false } }
        XCTAssertEqual(vertical.count, 1)
        guard case .line(let va, let vb, _, let vc) = vertical[0] else { return XCTFail() }
        XCTAssertEqual(va, PagePoint(x: 60, y: 0)); XCTAssertEqual(vb, PagePoint(x: 60, y: 792)); XCTAssertEqual(vc, TemplateGeometry.marginRuleColor)
    }

    func testGridAndDottedCountsScaleWithArea() {
        let grid = PaperTemplate.grid // spacing 18, margins 0
        let letter = lines(TemplateGeometry.primitives(for: grid, size: .letter))
        // Vertical: 18·k < 612, k ≥ 1 → k = 1...33 (33 lines). Horizontal: 18·k < 792 → k = 1...43 (43 lines).
        XCTAssertEqual(letter.count, 33 + 43)
        let doubled = lines(TemplateGeometry.primitives(for: grid, size: PageSize(width: 1224, height: 1584)))
        // 18k < 1224 → 67; 18k < 1584 → 87.
        XCTAssertEqual(doubled.count, 67 + 87)

        let dotted = PaperTemplate.dotted
        let d1 = dots(TemplateGeometry.primitives(for: dotted, size: .letter))
        XCTAssertEqual(d1.count, 33 * 43)
        let d2 = dots(TemplateGeometry.primitives(for: dotted, size: PageSize(width: 1224, height: 1584)))
        XCTAssertEqual(d2.count, 67 * 87)
        for d in d1 { if case .dot(_, let r, _) = d { XCTAssertEqual(r, TemplateGeometry.dotRadius) } }
    }

    func testCornellLayout() {
        let t = PaperTemplate.cornell // spacing 20, topMargin 60, leftMargin 160; summary band 80
        let prims = lines(TemplateGeometry.primitives(for: t, size: .letter))
        let horizontal = prims.compactMap { p -> (Double, Double, Double)? in
            if case .line(let a, let b, let w, _) = p, a.y == b.y { return (a.y, a.x, w) } else { return nil }
        }
        let vertical = prims.compactMap { p -> (Double, Double, Double)? in
            if case .line(let a, let b, _, _) = p, a.x == b.x { return (a.x, a.y, b.y) } else { return nil }
        }
        // Header rule at 60, summary rule at 792 − 80 = 712, both full width.
        XCTAssertTrue(horizontal.contains { $0.0 == 60 && $0.1 == 0 })
        XCTAssertTrue(horizontal.contains { $0.0 == 712 && $0.1 == 0 })
        // Cue column divider from the header to the summary band.
        XCTAssertEqual(vertical.count, 1)
        XCTAssertEqual(vertical[0].0, 160); XCTAssertEqual(vertical[0].1, 60); XCTAssertEqual(vertical[0].2, 712)
        // Notes rules: y = 80, 100, ..., < 712 → 32 rules, each starting at the cue column.
        let notes = horizontal.filter { $0.0 > 60 && $0.0 < 712 }
        XCTAssertEqual(notes.count, 32)
        XCTAssertTrue(notes.allSatisfy { $0.1 == 160 })
        // Nothing below the summary rule.
        XCTAssertFalse(horizontal.contains { $0.0 > 712 })
    }

    func testEngineeringGridHasHeavyLinesEveryFiveCellsAndMarginRules() {
        let t = PaperTemplate.engineering // spacing 14.4, margins 54 (= 3.75 cells, so the grid is anchored at the margins)
        let prims = lines(TemplateGeometry.primitives(for: t, size: .letter))
        let vertical = prims.compactMap { p -> (x: Double, w: Double)? in
            if case .line(let a, let b, let w, _) = p, a.x == b.x { return (a.x, w) } else { return nil }
        }
        let horizontal = prims.compactMap { p -> (y: Double, w: Double)? in
            if case .line(let a, let b, let w, _) = p, a.y == b.y { return (a.y, w) } else { return nil }
        }
        // Vertical lines at 54 + 14.4k inside (0, 612): k = −3...38 → 42 lines; horizontal: k = −3...51 → 55 lines.
        XCTAssertEqual(vertical.count, 42)
        XCTAssertEqual(horizontal.count, 55)
        // Margin rules are the heaviest lines.
        XCTAssertEqual(vertical.filter { $0.w == TemplateGeometry.heavyRuleWidth }.map(\.x), [54])
        XCTAssertEqual(horizontal.filter { $0.w == TemplateGeometry.heavyRuleWidth }.map(\.y), [54])
        // Every fifth cell from the margin is a major line: x = 54 + 72 = 126, 198, ...
        let majors = vertical.filter { $0.w == TemplateGeometry.ruleWidth }.map(\.x)
        XCTAssertEqual(majors.count, 7)
        XCTAssertEqual(majors[0], 126, accuracy: 1e-9)
        XCTAssertEqual(majors[1], 198, accuracy: 1e-9)
        // The rest are fine lines.
        XCTAssertEqual(vertical.filter { $0.w == TemplateGeometry.fineGridWidth }.count, 42 - 1 - 7)
        // Counts scale with size.
        let big = lines(TemplateGeometry.primitives(for: t, size: PageSize(width: 1224, height: 1584)))
        XCTAssertGreaterThan(big.count, prims.count * 3 / 2)
    }

    func testDegenerateSpacingProducesNoRulesButStaysValid() {
        var t = PaperTemplate.lined; t.spacing = 0
        XCTAssertEqual(TemplateGeometry.primitives(for: t, size: .letter).count, 1)
        var tiny = PaperTemplate.grid; tiny.spacing = 0.0001
        let prims = TemplateGeometry.primitives(for: tiny, size: PageSize(width: 10, height: 10))
        assertInsidePage(prims, size: PageSize(width: 10, height: 10))
        XCTAssertTrue(TemplateGeometry.primitives(for: .lined, size: PageSize(width: 0, height: 0)).count == 1)
    }
}
