import CoreGraphics
import UIKit
import DocumentCore

// Bridges the portable DocumentCore geometry (page space, PDF points, y down)
// to CoreGraphics/UIKit types. Both use the same affine convention
// (x' = a·x + c·y + tx, y' = b·x + d·y + ty), so the conversions are
// component-wise and lossless.

extension CGPoint {
    init(_ p: PagePoint) { self.init(x: p.x, y: p.y) }
}

extension PagePoint {
    init(_ p: CGPoint) { self.init(x: Double(p.x), y: Double(p.y)) }
}

extension CGSize {
    init(_ s: PageSize) { self.init(width: s.width, height: s.height) }
}

extension PageSize {
    init(_ s: CGSize) { self.init(width: Double(s.width), height: Double(s.height)) }
}

extension CGRect {
    init(_ r: PageRect) {
        let s = r.standardized
        self.init(x: s.minX, y: s.minY, width: s.width, height: s.height)
    }
}

extension PageRect {
    init(_ r: CGRect) {
        let s = r.standardized
        self.init(x: Double(s.origin.x), y: Double(s.origin.y), width: Double(s.width), height: Double(s.height))
    }
}

extension CGAffineTransform {
    init(_ t: PageTransform) { self.init(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty) }
}

extension PageTransform {
    init(_ t: CGAffineTransform) {
        self.init(a: Double(t.a), b: Double(t.b), c: Double(t.c), d: Double(t.d), tx: Double(t.tx), ty: Double(t.ty))
    }

    /// The layer transform that displays a view whose untransformed frame origin
    /// is `layerOrigin` (in its superview's page-space coordinates, anchor point
    /// at the top-left corner) as if the page-space transform `self` had been
    /// applied to it. With anchor (0,0) a layer maps a local point l to
    /// `position + M·l`; we need `T(P + l)`, so `M` shares the linear part of
    /// `T` and its translation is `T(P) − P`.
    func layerTransform(forLayerOrigin origin: PagePoint) -> CGAffineTransform {
        let moved = apply(origin)
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: moved.x - origin.x, ty: moved.y - origin.y)
    }
}

extension UIColor {
    convenience init(_ c: RGBAColor) {
        self.init(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    /// sRGB components of the colour (any colour space is converted first).
    var rgbaColor: RGBAColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        if getRed(&r, green: &g, blue: &b, alpha: &a) {
            return RGBAColor(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
        }
        var white: CGFloat = 0
        if getWhite(&white, alpha: &a) {
            return RGBAColor(red: Double(white), green: Double(white), blue: Double(white), alpha: Double(a))
        }
        return .black
    }
}

extension CGColor {
    static func make(_ c: RGBAColor) -> CGColor {
        CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}
