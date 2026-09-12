import CoreGraphics
import UIKit
import DocumentCore
import PageGeometry

// Interchange-private bridging between DocumentCore geometry and CoreGraphics.
// Deliberately named functions (not `init` overloads on CG types) so this
// directory never redeclares the extensions other parts of the app own.

enum IXGeometry {
    static func point(_ p: PagePoint) -> CGPoint { CGPoint(x: p.x, y: p.y) }
    static func size(_ s: PageSize) -> CGSize { CGSize(width: s.width, height: s.height) }
    static func rect(_ r: PageRect) -> CGRect {
        let s = r.standardized
        return CGRect(x: s.minX, y: s.minY, width: s.width, height: s.height)
    }
    static func pageRect(_ r: CGRect) -> PageRect {
        let s = r.standardized
        return PageRect(x: Double(s.minX), y: Double(s.minY), width: Double(s.width), height: Double(s.height))
    }
    static func transform(_ t: PageTransform) -> CGAffineTransform {
        CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
    }
    static func uiColor(_ c: RGBAColor) -> UIColor {
        UIColor(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
    }
    static func cgColor(_ c: RGBAColor) -> CGColor {
        CGColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
    }

    /// Draws a CGImage into a y-down (UIKit-style) context so it appears upright.
    /// `CGContext.draw(_:in:)` assumes a y-up context; flipping locally keeps the
    /// call independent of whether a UIKit current context is pushed.
    static func drawImage(_ image: CGImage, in rect: CGRect, context ctx: CGContext, alpha: CGFloat = 1, blend: CGBlendMode = .normal) {
        guard rect.width > 0, rect.height > 0 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setBlendMode(blend)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// Aspect-fit `imageSize` inside `bounds`, centered.
    static func fitted(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}

extension UIImage {
    /// A copy whose pixel data is stored upright (`imageOrientation == .up`), so
    /// `cgImage` can be drawn directly. Camera JPEGs carry EXIF orientation; the
    /// original bytes stored as an asset are untouched, only the drawn copy is normalized.
    func ixNormalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
