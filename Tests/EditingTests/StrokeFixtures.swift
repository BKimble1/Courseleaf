import Foundation
import DocumentCore
@testable import Editing

/// Deterministic page-space polylines for the gesture recognisers. Every shape
/// is generated from a formula so a failing threshold can be traced to a number
/// rather than to a recorded blob nobody can reason about.
enum StrokeFixtures {

    static func samples(_ points: [PagePoint], duration: Double?) -> [StrokeSample] {
        guard let duration, points.count > 1 else { return points.map { StrokeSample(location: $0) } }
        let step = duration / Double(points.count - 1)
        return points.enumerated().map { StrokeSample(location: $0.element, timeOffset: Double($0.offset) * step) }
    }

    /// Straight line, densely sampled.
    static func line(from a: PagePoint, to b: PagePoint, samples count: Int = 40) -> [PagePoint] {
        (0...count).map { i in
            let t = Double(i) / Double(count)
            return PagePoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// Crossing a word out: `passes` horizontal traversals of the same span,
    /// drifting only within a narrow band.
    static func crossOut(x0: Double, x1: Double, y: Double, bandHeight: Double = 10,
                         passes: Int = 5, perPass: Int = 24) -> [PagePoint] {
        var out: [PagePoint] = []
        for pass in 0..<passes {
            let forwards = pass % 2 == 0
            let from = forwards ? x0 : x1
            let to = forwards ? x1 : x0
            // The band drifts a little, as a hand does, but never walks away.
            let offset = (Double(pass % 3) - 1) * bandHeight / 3
            for i in 0...perPass {
                let t = Double(i) / Double(perPass)
                out.append(PagePoint(x: from + (to - from) * t, y: y + offset))
            }
        }
        return out
    }

    /// Shading a region: back and forth while advancing steadily across, so the
    /// stroke fills an area instead of retracing a band.
    static func shading(rect: PageRect, passes: Int = 8, perPass: Int = 20) -> [PagePoint] {
        var out: [PagePoint] = []
        for pass in 0..<passes {
            let forwards = pass % 2 == 0
            let from = forwards ? rect.minX : rect.maxX
            let to = forwards ? rect.maxX : rect.minX
            let y = rect.minY + rect.height * Double(pass) / Double(max(passes - 1, 1))
            for i in 0...perPass {
                let t = Double(i) / Double(perPass)
                out.append(PagePoint(x: from + (to - from) * t, y: y))
            }
        }
        return out
    }

    /// A sine wave: wiggly across its axis, monotonic along it.
    static func sineWave(x0: Double, x1: Double, y: Double, amplitude: Double,
                         periods: Double, samples count: Int = 160) -> [PagePoint] {
        (0...count).map { i in
            let t = Double(i) / Double(count)
            let x = x0 + (x1 - x0) * t
            return PagePoint(x: x, y: y + amplitude * sin(t * periods * 2 * Double.pi))
        }
    }

    /// A row of small loops, the way repeated letters ("eeee") are written:
    /// each loop doubles back a little, the word advances steadily.
    static func repeatedLoops(x0: Double, y: Double, loops: Int = 6, width: Double = 16,
                              height: Double = 22, perLoop: Int = 24) -> [PagePoint] {
        var out: [PagePoint] = []
        for loop in 0..<loops {
            let originX = x0 + Double(loop) * width
            for i in 0...perLoop {
                let t = Double(i) / Double(perLoop) * 2 * Double.pi
                out.append(PagePoint(x: originX + width * 0.5 * (1 - cos(t)) + width * 0.25 * (Double(i) / Double(perLoop)),
                                     y: y - height * 0.5 * sin(t)))
            }
        }
        return out
    }

    /// Engineering hatching is a set of separate parallel strokes, not one
    /// gesture; each is returned on its own so the recogniser judges each one.
    static func hatching(rect: PageRect, lines: Int = 6) -> [[PagePoint]] {
        (0..<lines).map { i in
            let t = Double(i) / Double(max(lines - 1, 1))
            let x = rect.minX + rect.width * t
            return line(from: PagePoint(x: x, y: rect.minY), to: PagePoint(x: x + rect.width * 0.3, y: rect.maxY))
        }
    }

    /// A deliberate zigzag drawing (a lightning bolt): a handful of long
    /// segments with real forward progress, drawn once.
    static func zigzagDrawing(x0: Double, y0: Double, width: Double = 120, height: Double = 60,
                              segments: Int = 4) -> [PagePoint] {
        var corners: [PagePoint] = []
        for i in 0...segments {
            let t = Double(i) / Double(segments)
            corners.append(PagePoint(x: x0 + width * t, y: y0 + (i % 2 == 0 ? 0 : height)))
        }
        var out: [PagePoint] = []
        for i in 1..<corners.count { out += line(from: corners[i - 1], to: corners[i], samples: 16) }
        return out
    }

    /// A wide summation sign: the mathematical notation closest to a cross-out,
    /// because it genuinely reverses along its own long axis.
    static func summationSign(x0: Double, y0: Double, width: Double = 200, height: Double = 60) -> [PagePoint] {
        let tr = PagePoint(x: x0 + width, y: y0)
        let tl = PagePoint(x: x0, y: y0)
        let mid = PagePoint(x: x0 + width * 0.5, y: y0 + height * 0.5)
        let bl = PagePoint(x: x0, y: y0 + height)
        let br = PagePoint(x: x0 + width, y: y0 + height)
        return line(from: tr, to: tl, samples: 24) + line(from: tl, to: mid, samples: 16)
            + line(from: mid, to: bl, samples: 16) + line(from: bl, to: br, samples: 24)
    }

    /// A circle, drawn with a wobble so it is not already perfect.
    static func circle(center: PagePoint, radius: Double, wobble: Double = 1.5, samples count: Int = 96) -> [PagePoint] {
        (0...count).map { i in
            let t = Double(i) / Double(count) * 2 * Double.pi
            let r = radius + wobble * sin(t * 5)
            return PagePoint(x: center.x + r * cos(t), y: center.y + r * sin(t))
        }
    }

    /// A rectangle traced by hand, with wobble along each side.
    static func rectangle(_ rect: PageRect, wobble: Double = 1.2, perSide: Int = 30) -> [PagePoint] {
        let corners = [PagePoint(x: rect.minX, y: rect.minY), PagePoint(x: rect.maxX, y: rect.minY),
                       PagePoint(x: rect.maxX, y: rect.maxY), PagePoint(x: rect.minX, y: rect.maxY),
                       PagePoint(x: rect.minX, y: rect.minY)]
        var out: [PagePoint] = []
        for i in 1..<corners.count {
            let a = corners[i - 1], b = corners[i]
            for j in 0..<perSide {
                let t = Double(j) / Double(perSide)
                let nx = -(b.y - a.y), ny = (b.x - a.x)
                let length = max((nx * nx + ny * ny).squareRoot(), 1e-9)
                let w = wobble * sin(t * Double.pi * 3)
                out.append(PagePoint(x: a.x + (b.x - a.x) * t + nx / length * w,
                                     y: a.y + (b.y - a.y) * t + ny / length * w))
            }
        }
        out.append(corners[0])
        return out
    }

    /// Rotates a polyline about a point, for the "page rotation" cases.
    static func rotated(_ points: [PagePoint], by radians: Double, about pivot: PagePoint) -> [PagePoint] {
        let c = cos(radians), s = sin(radians)
        return points.map { p in
            let dx = p.x - pivot.x, dy = p.y - pivot.y
            return PagePoint(x: pivot.x + dx * c - dy * s, y: pivot.y + dx * s + dy * c)
        }
    }

    /// Scales a polyline about the origin, for the "small and zoomed" cases.
    static func scaled(_ points: [PagePoint], by factor: Double) -> [PagePoint] {
        points.map { PagePoint(x: $0.x * factor, y: $0.y * factor) }
    }
}
