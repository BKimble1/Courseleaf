import Foundation
import DocumentCore

/// One drawing primitive of a procedural paper template, in page points.
public enum TemplatePrimitive: Hashable, Sendable {
    case line(from: PagePoint, to: PagePoint, width: Double, color: RGBAColor)
    case dot(center: PagePoint, radius: Double, color: RGBAColor)
    case rect(PageRect, fill: RGBAColor)

    /// Axis-aligned bounds of the primitive's geometry (line end points, dot disc, rect).
    public var bounds: PageRect {
        switch self {
        case .line(let a, let b, _, _): return PageRect.bounding([a, b]) ?? .zero
        case .dot(let c, let r, _): return PageRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .rect(let r, _): return r.standardized
        }
    }
}

/// Geometry of the original paper templates. Output is resolution
/// independent so the same primitives draw the on-screen background, the
/// thumbnail and the PDF/image export.
public enum TemplateGeometry {
    /// Stroke width of ordinary rules and grid lines.
    public static let ruleWidth: Double = 0.75
    /// Stroke width of the fine engineering grid.
    public static let fineGridWidth: Double = 0.4
    /// Stroke width of the heavier engineering major grid and margin rules.
    public static let heavyRuleWidth: Double = 1.2
    /// Dot radius for dotted paper.
    public static let dotRadius: Double = 1.0
    /// Colour of the vertical margin rule on lined paper (classic pale red).
    public static let marginRuleColor = RGBAColor(hex: "#E8A9A9")!
    /// Summary band height on Cornell paper, in multiples of `spacing`.
    public static let cornellSummaryRows: Double = 4

    /// Every primitive needed to draw `template` on a page of `size`, back to
    /// front. The first primitive is always the paper rectangle. Nothing lies
    /// outside the page; lines on the page edge itself are omitted.
    public static func primitives(for template: PaperTemplate, size: PageSize) -> [TemplatePrimitive] {
        let page = PageRect(origin: .zero, size: size)
        var out: [TemplatePrimitive] = [.rect(page, fill: template.paperColor)]
        guard size.isValid else { return out }
        let spacing = template.spacing
        let color = template.lineColor
        let w = size.width, h = size.height
        let top = clamp(template.topMargin, 0, h)
        let left = clamp(template.leftMargin, 0, w)

        switch template.kind {
        case .blank:
            break

        case .lined:
            for y in positions(start: top, spacing: spacing, limit: h) {
                out.append(.line(from: PagePoint(x: 0, y: y), to: PagePoint(x: w, y: y), width: ruleWidth, color: color))
            }
            if left > 0 && left < w {
                out.append(.line(from: PagePoint(x: left, y: 0), to: PagePoint(x: left, y: h), width: ruleWidth, color: marginRuleColor))
            }

        case .grid:
            for x in positions(start: left, spacing: spacing, limit: w) {
                out.append(.line(from: PagePoint(x: x, y: 0), to: PagePoint(x: x, y: h), width: ruleWidth, color: color))
            }
            for y in positions(start: top, spacing: spacing, limit: h) {
                out.append(.line(from: PagePoint(x: 0, y: y), to: PagePoint(x: w, y: y), width: ruleWidth, color: color))
            }

        case .dotted:
            let xs = positions(start: left, spacing: spacing, limit: w)
            let ys = positions(start: top, spacing: spacing, limit: h)
            for y in ys {
                for x in xs {
                    out.append(.dot(center: PagePoint(x: x, y: y), radius: dotRadius, color: color))
                }
            }

        case .cornell:
            let summaryHeight = min(cornellSummaryRows * max(spacing, 0), h)
            let summaryTop = h - summaryHeight
            // Header rule (bottom edge of the header band).
            if top > 0 && top < h {
                out.append(.line(from: PagePoint(x: 0, y: top), to: PagePoint(x: w, y: top), width: heavyRuleWidth, color: color))
            }
            // Summary rule (top edge of the summary band).
            if summaryTop > 0 && summaryTop < h && summaryTop > top {
                out.append(.line(from: PagePoint(x: 0, y: summaryTop), to: PagePoint(x: w, y: summaryTop), width: heavyRuleWidth, color: color))
            }
            // Cue column divider between header and summary band.
            if left > 0 && left < w && summaryTop > top {
                out.append(.line(from: PagePoint(x: left, y: top), to: PagePoint(x: left, y: summaryTop), width: heavyRuleWidth, color: color))
            }
            // Rules in the notes area (right of the cue column, between header and summary).
            if summaryTop > top {
                for y in positions(start: top, spacing: spacing, limit: summaryTop) where y > top {
                    out.append(.line(from: PagePoint(x: left, y: y), to: PagePoint(x: w, y: y), width: ruleWidth, color: color))
                }
            }

        case .engineering:
            // Grid anchored at (leftMargin, topMargin) so the heavy lines coincide with the margin rules.
            for (x, major) in anchoredPositions(anchor: left, spacing: spacing, limit: w) {
                let isMargin = x == left && left > 0
                let width = isMargin ? heavyRuleWidth : (major ? ruleWidth : fineGridWidth)
                out.append(.line(from: PagePoint(x: x, y: 0), to: PagePoint(x: x, y: h), width: width, color: color))
            }
            for (y, major) in anchoredPositions(anchor: top, spacing: spacing, limit: h) {
                let isMargin = y == top && top > 0
                let width = isMargin ? heavyRuleWidth : (major ? ruleWidth : fineGridWidth)
                out.append(.line(from: PagePoint(x: 0, y: y), to: PagePoint(x: w, y: y), width: width, color: color))
            }
            // Margin rules are drawn even when the margin is not a grid multiple (they always are here) or spacing is zero.
            if spacing <= 0 {
                if left > 0 && left < w {
                    out.append(.line(from: PagePoint(x: left, y: 0), to: PagePoint(x: left, y: h), width: heavyRuleWidth, color: color))
                }
                if top > 0 && top < h {
                    out.append(.line(from: PagePoint(x: 0, y: top), to: PagePoint(x: w, y: top), width: heavyRuleWidth, color: color))
                }
            }
        }
        return out
    }

    /// `start + k·spacing` for k ≥ 0, strictly inside `(0, limit)`.
    static func positions(start: Double, spacing: Double, limit: Double) -> [Double] {
        guard spacing > 0, spacing.isFinite, limit > 0 else { return [] }
        var result: [Double] = []
        var k = 0
        while true {
            let p = start + Double(k) * spacing
            if p >= limit { break }
            if p > 0 { result.append(p) }
            k += 1
            if k > 100_000 { break }
        }
        return result
    }

    /// Grid positions `anchor + k·spacing` for every integer k (negative too)
    /// strictly inside `(0, limit)`, flagged `major` when k is a multiple of 5.
    static func anchoredPositions(anchor: Double, spacing: Double, limit: Double) -> [(Double, Bool)] {
        guard spacing > 0, spacing.isFinite, limit > 0 else { return [] }
        let kMin = Int((-anchor / spacing).rounded(.down)) - 1
        let kMax = Int(((limit - anchor) / spacing).rounded(.up)) + 1
        guard kMax - kMin < 200_000 else { return [] }
        var result: [(Double, Bool)] = []
        for k in kMin...kMax {
            let p = anchor + Double(k) * spacing
            if p > 0 && p < limit { result.append((p, k % 5 == 0)) }
        }
        return result
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isFinite ? min(max(v, lo), hi) : lo }
}
