import Foundation

// Portable geometry primitives. All document coordinates are expressed in
// *page space*: PDF points (1/72 inch), origin at the top-left corner of the
// visible (cropped, rotated) page, x to the right, y downward. See
// docs/ARCHITECTURE.md "Coordinate system". These types deliberately avoid
// CoreGraphics so the model and its tests build on Linux; the app bridges
// them to CGPoint/CGRect/CGAffineTransform.

public struct PagePoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = PagePoint(x: 0, y: 0)

    public func distance(to other: PagePoint) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }
    public func offset(dx: Double, dy: Double) -> PagePoint { PagePoint(x: x + dx, y: y + dy) }
}

public struct PageSize: Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }

    /// US Letter, 8.5 x 11 inches.
    public static let letter = PageSize(width: 612, height: 792)
    /// ISO A4.
    public static let a4 = PageSize(width: 595.276, height: 841.89)
    public var swapped: PageSize { PageSize(width: height, height: width) }
    public var isValid: Bool { width.isFinite && height.isFinite && width > 0 && height > 0 }
}

public struct PageRect: Hashable, Codable, Sendable {
    public var origin: PagePoint
    public var size: PageSize
    public init(origin: PagePoint, size: PageSize) { self.origin = origin; self.size = size }
    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = PagePoint(x: x, y: y); size = PageSize(width: width, height: height)
    }
    public static let zero = PageRect(x: 0, y: 0, width: 0, height: 0)
    /// The unit square, used for normalized sub-rectangles (image crops, shape endpoints).
    public static let unit = PageRect(x: 0, y: 0, width: 1, height: 1)

    public var minX: Double { min(origin.x, origin.x + size.width) }
    public var minY: Double { min(origin.y, origin.y + size.height) }
    public var maxX: Double { max(origin.x, origin.x + size.width) }
    public var maxY: Double { max(origin.y, origin.y + size.height) }
    public var width: Double { abs(size.width) }
    public var height: Double { abs(size.height) }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }
    public var center: PagePoint { PagePoint(x: midX, y: midY) }
    public var isEmpty: Bool { width == 0 || height == 0 }
    public var isFinite: Bool { [minX, minY, maxX, maxY].allSatisfy { $0.isFinite } }

    /// Normalizes negative sizes so origin is the top-left corner.
    public var standardized: PageRect { PageRect(x: minX, y: minY, width: width, height: height) }

    public func contains(_ point: PagePoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
    public func contains(_ other: PageRect) -> Bool {
        other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }
    public func intersects(_ other: PageRect) -> Bool {
        !(other.minX > maxX || other.maxX < minX || other.minY > maxY || other.maxY < minY)
    }
    public func intersection(_ other: PageRect) -> PageRect? {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 >= x0, y1 >= y0 else { return nil }
        return PageRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    public func union(_ other: PageRect) -> PageRect {
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        let x1 = max(maxX, other.maxX), y1 = max(maxY, other.maxY)
        return PageRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    public func insetBy(dx: Double, dy: Double) -> PageRect {
        PageRect(x: minX + dx, y: minY + dy, width: width - 2 * dx, height: height - 2 * dy)
    }
    public func offsetBy(dx: Double, dy: Double) -> PageRect {
        PageRect(x: minX + dx, y: minY + dy, width: width, height: height)
    }
    public var corners: [PagePoint] {
        [PagePoint(x: minX, y: minY), PagePoint(x: maxX, y: minY), PagePoint(x: maxX, y: maxY), PagePoint(x: minX, y: maxY)]
    }
    /// Axis-aligned bounding box of this rectangle after applying `transform`.
    public func applying(_ transform: PageTransform) -> PageRect {
        PageRect.bounding(corners.map { transform.apply($0) }) ?? .zero
    }
    /// Smallest rectangle containing all points, or nil when empty.
    public static func bounding(_ points: [PagePoint]) -> PageRect? {
        guard let first = points.first else { return nil }
        var x0 = first.x, y0 = first.y, x1 = first.x, y1 = first.y
        for p in points.dropFirst() { x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y) }
        return PageRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    /// Maps a normalized (unit-square) rectangle into this rectangle.
    public func denormalizing(_ unit: PageRect) -> PageRect {
        PageRect(x: minX + unit.minX * width, y: minY + unit.minY * height,
                 width: unit.width * width, height: unit.height * height)
    }
}

/// Affine transform using the PDF/CoreGraphics convention:
/// x' = a*x + c*y + tx, y' = b*x + d*y + ty.
public struct PageTransform: Hashable, Codable, Sendable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    public static let identity = PageTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    public static func translation(x: Double, y: Double) -> PageTransform { PageTransform(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y) }
    public static func scale(x: Double, y: Double) -> PageTransform { PageTransform(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0) }
    public static func scale(_ s: Double) -> PageTransform { scale(x: s, y: s) }
    public static func rotation(radians: Double) -> PageTransform {
        let cs = cos(radians), sn = sin(radians)
        return PageTransform(a: cs, b: sn, c: -sn, d: cs, tx: 0, ty: 0)
    }
    /// Rotation about an arbitrary point.
    public static func rotation(radians: Double, about p: PagePoint) -> PageTransform {
        translation(x: -p.x, y: -p.y).concatenating(rotation(radians: radians)).concatenating(translation(x: p.x, y: p.y))
    }
    public var isIdentity: Bool { self == .identity }
    public var determinant: Double { a * d - b * c }

    public func apply(_ p: PagePoint) -> PagePoint {
        PagePoint(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty)
    }
    /// Returns `self` followed by `t` (apply self first, then t).
    public func concatenating(_ t: PageTransform) -> PageTransform {
        PageTransform(
            a: a * t.a + b * t.c, b: a * t.b + b * t.d,
            c: c * t.a + d * t.c, d: c * t.b + d * t.d,
            tx: tx * t.a + ty * t.c + t.tx, ty: tx * t.b + ty * t.d + t.ty)
    }
    public func inverted() -> PageTransform? {
        let det = determinant
        guard det != 0, det.isFinite else { return nil }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return PageTransform(a: ia, b: ib, c: ic, d: id, tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty))
    }
    public func isApproximatelyEqual(to other: PageTransform, tolerance: Double = 1e-9) -> Bool {
        abs(a - other.a) <= tolerance && abs(b - other.b) <= tolerance && abs(c - other.c) <= tolerance &&
        abs(d - other.d) <= tolerance && abs(tx - other.tx) <= tolerance && abs(ty - other.ty) <= tolerance
    }
}

/// Page rotation in degrees, clockwise when displayed (PDF /Rotate semantics).
public enum PageRotation: Int, Codable, Hashable, Sendable, CaseIterable {
    case degrees0 = 0, degrees90 = 90, degrees180 = 180, degrees270 = 270

    /// Normalizes any multiple of 90 (including negatives) into a case.
    public init?(degrees: Int) {
        let normalized = ((degrees % 360) + 360) % 360
        self.init(rawValue: normalized)
    }
    public var swapsWidthAndHeight: Bool { self == .degrees90 || self == .degrees270 }
    public var radians: Double { Double(rawValue) * .pi / 180 }
    public func rotated(by delta: PageRotation) -> PageRotation { PageRotation(degrees: rawValue + delta.rawValue)! }
}

/// sRGB color with straight alpha, components in 0...1.
public struct RGBAColor: Hashable, Codable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    /// Parses "#RRGGBB" or "#RRGGBBAA".
    public init?(hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 { s += "FF" }
        let value = UInt64(s, radix: 16) ?? v
        red = Double((value >> 24) & 0xFF) / 255; green = Double((value >> 16) & 0xFF) / 255
        blue = Double((value >> 8) & 0xFF) / 255; alpha = Double(value & 0xFF) / 255
    }
    public var hexString: String {
        func h(_ v: Double) -> String { String(format: "%02X", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + h(red) + h(green) + h(blue) + h(alpha)
    }
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
    public func withAlpha(_ a: Double) -> RGBAColor { RGBAColor(red: red, green: green, blue: blue, alpha: a) }
}
