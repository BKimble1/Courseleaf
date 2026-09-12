import Foundation
import UIKit
import PDFKit
import PencilKit
import DocumentCore
import PageGeometry

// CoreGraphics drawing of page content in page space (y down, PDF points).
// Shared by the tiled background layer, the placeholder thumbnails and the
// object views. The context is expected to be a UIKit context (origin top-left).

/// Resolved background for drawing. `pdf` carries the mapping that positions
/// the PDF user space under page space (`PageMapping.pdfUserToPage`).
enum PageBackgroundContent {
    case empty(paperColor: RGBAColor)
    case template([TemplatePrimitive], paperColor: RGBAColor)
    case pdf(PDFPage, mapping: PageMapping, assetID: AssetID, documents: PDFDocumentCache)
    case image(UIImage)
}

enum PageRenderer {
    /// Draws the background into `ctx` clipped to `rect` (page space).
    static func drawBackground(_ content: PageBackgroundContent, pageSize: CGSize, in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch content {
        case .empty(let paper):
            ctx.setFillColor(CGColor.make(paper))
            ctx.fill(rect)
        case .template(let primitives, let paper):
            ctx.setFillColor(CGColor.make(paper))
            ctx.fill(rect)
            drawPrimitives(primitives, in: ctx, rect: rect)
        case .image(let image):
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(rect)
            let target = fitted(imageSize: image.size, in: CGRect(origin: .zero, size: pageSize))
            UIGraphicsPushContext(ctx)
            image.draw(in: target)
            UIGraphicsPopContext()
        case .pdf(let page, let mapping, let assetID, let documents):
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(rect)
            ctx.clip(to: rect)
            // Page space <- PDF user space: apply the tested PageGeometry transform, then let PDFKit
            // draw the page in its own user space, clipped to the crop box.
            ctx.concatenate(CGAffineTransform(mapping.pdfUserToPage))
            ctx.clip(to: CGRect(mapping.cropBox))
            ctx.interpolationQuality = .high
            documents.withDrawLock(for: assetID) {
                page.draw(with: .cropBox, to: ctx)
            }
        }
    }

    static func drawPrimitives(_ primitives: [TemplatePrimitive], in ctx: CGContext, rect: CGRect) {
        let visible = PageRect(rect)
        for primitive in primitives {
            // The first primitive is the paper rectangle, already painted by the caller.
            guard primitive.bounds.insetBy(dx: -2, dy: -2).intersects(visible) else { continue }
            switch primitive {
            case .rect(let r, let fill):
                ctx.setFillColor(CGColor.make(fill))
                ctx.fill(CGRect(r))
            case .line(let from, let to, let width, let color):
                ctx.setStrokeColor(CGColor.make(color))
                ctx.setLineWidth(width)
                ctx.setLineCap(.butt)
                ctx.move(to: CGPoint(from))
                ctx.addLine(to: CGPoint(to))
                ctx.strokePath()
            case .dot(let center, let radius, let color):
                ctx.setFillColor(CGColor.make(color))
                ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            }
        }
    }

    static func fitted(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: Objects

    /// Path of a shape inside `frame` (unrotated), in page space.
    static func shapePath(_ shape: ShapeContent, in frame: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        func point(_ unit: PagePoint) -> CGPoint {
            CGPoint(x: frame.minX + unit.x * frame.width, y: frame.minY + unit.y * frame.height)
        }
        switch shape.kind {
        case .rectangle:
            path.append(UIBezierPath(rect: frame))
        case .ellipse:
            path.append(UIBezierPath(ovalIn: frame))
        case .line:
            path.move(to: point(shape.start)); path.addLine(to: point(shape.end))
        case .arrow:
            let a = point(shape.start), b = point(shape.end)
            path.move(to: a); path.addLine(to: b)
            let length = hypot(b.x - a.x, b.y - a.y)
            let head = min(max(shape.strokeWidth * 5, 10), max(length / 2, 1))
            if length > 0.5 {
                let angle = atan2(b.y - a.y, b.x - a.x)
                let left = CGPoint(x: b.x - head * cos(angle - .pi / 6), y: b.y - head * sin(angle - .pi / 6))
                let right = CGPoint(x: b.x - head * cos(angle + .pi / 6), y: b.y - head * sin(angle + .pi / 6))
                path.move(to: left); path.addLine(to: b); path.addLine(to: right)
            }
        }
        path.lineWidth = shape.strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    static func font(for text: TextContent) -> UIFont {
        let weight: UIFont.Weight
        switch text.weight {
        case .regular: weight = .regular
        case .medium: weight = .medium
        case .semibold: weight = .semibold
        case .bold: weight = .bold
        }
        let base = UIFont.systemFont(ofSize: text.fontSize, weight: weight)
        let design: UIFontDescriptor.SystemDesign
        switch text.design {
        case .standard: design = .default
        case .serif: design = .serif
        case .monospaced: design = .monospaced
        case .rounded: design = .rounded
        }
        if design == .default { return base }
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: text.fontSize)
    }

    static func paragraphStyle(for text: TextContent) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch text.alignment {
        case .leading: style.alignment = .natural
        case .center: style.alignment = .center
        case .trailing: style.alignment = .right
        }
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static func attributedString(for text: TextContent) -> NSAttributedString {
        NSAttributedString(string: text.text, attributes: [
            .font: font(for: text),
            .foregroundColor: UIColor(text.color),
            .paragraphStyle: paragraphStyle(for: text),
        ])
    }

    /// Draws an object (rotation applied about the frame centre) in page space.
    static func drawObject(_ object: CanvasObject, image: UIImage?, in ctx: CGContext) {
        let frame = CGRect(object.frame)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if object.rotation != 0 {
            ctx.translateBy(x: frame.midX, y: frame.midY)
            ctx.rotate(by: object.rotation)
            ctx.translateBy(x: -frame.midX, y: -frame.midY)
        }
        switch object.content {
        case .image(let content):
            guard let image, let cg = image.cgImage else { return }
            let crop = content.crop.standardized
            let px = CGRect(x: crop.minX * CGFloat(cg.width), y: crop.minY * CGFloat(cg.height),
                            width: crop.width * CGFloat(cg.width), height: crop.height * CGFloat(cg.height))
            let cropped = (crop == .unit ? cg : cg.cropping(to: px)) ?? cg
            ctx.setAlpha(content.opacity)
            UIGraphicsPushContext(ctx)
            UIImage(cgImage: cropped, scale: 1, orientation: image.imageOrientation).draw(in: frame)
            UIGraphicsPopContext()
        case .shape(let shape):
            let path = shapePath(shape, in: frame)
            if let fill = shape.fillColor, shape.kind == .rectangle || shape.kind == .ellipse {
                ctx.setFillColor(CGColor.make(fill))
                ctx.addPath(path.cgPath); ctx.fillPath()
            }
            ctx.setStrokeColor(CGColor.make(shape.strokeColor))
            ctx.setLineWidth(shape.strokeWidth)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addPath(path.cgPath); ctx.strokePath()
        case .text(let text):
            UIGraphicsPushContext(ctx)
            attributedString(for: text).draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            UIGraphicsPopContext()
        case .tape(let tape):
            if tape.isRevealed {
                ctx.setStrokeColor(CGColor.make(tape.color.withAlpha(0.9)))
                ctx.setLineWidth(1.5)
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 4).cgPath); ctx.strokePath()
            } else {
                ctx.setFillColor(CGColor.make(tape.color))
                ctx.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 4).cgPath); ctx.fillPath()
                if let label = tape.label, !label.isEmpty {
                    UIGraphicsPushContext(ctx)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: min(14, max(8, frame.height * 0.5)), weight: .medium),
                        .foregroundColor: UIColor.black.withAlphaComponent(0.7),
                    ]
                    let size = (label as NSString).size(withAttributes: attrs)
                    (label as NSString).draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), withAttributes: attrs)
                    UIGraphicsPopContext()
                }
            }
        }
    }

    // MARK: Whole page (thumbnails)

    struct PageRenderInput {
        var page: Page
        var background: PageBackgroundContent
        var images: [ObjectID: UIImage]
        var drawing: PKDrawing?
    }

    /// Renders a page composite (background, images, ink, objects; tape drawn last)
    /// into an image of `size` points. Safe to call off the main thread.
    static func renderPage(_ input: PageRenderInput, size: CGSize, scale: CGFloat) -> UIImage {
        let pageSize = CGSize(input.page.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            let ctx = rendererContext.cgContext
            let sx = size.width / max(pageSize.width, 1), sy = size.height / max(pageSize.height, 1)
            ctx.scaleBy(x: sx, y: sy)
            let full = CGRect(origin: .zero, size: pageSize)
            drawBackground(input.background, pageSize: pageSize, in: ctx, rect: full)
            let objects = input.page.objects
            for object in objects where object.kind == .image {
                drawObject(object, image: input.images[object.id], in: ctx)
            }
            if let drawing = input.drawing, !drawing.strokes.isEmpty {
                let bounds = drawing.bounds.intersection(full)
                if !bounds.isNull, bounds.width > 0, bounds.height > 0 {
                    let inkScale = max(1, min(scale * max(sx, sy), 4))
                    let image = drawing.image(from: bounds, scale: inkScale)
                    UIGraphicsPushContext(ctx)
                    image.draw(in: bounds)
                    UIGraphicsPopContext()
                }
            }
            for object in objects where object.kind == .text || object.kind == .shape {
                drawObject(object, image: nil, in: ctx)
            }
            for object in objects where object.kind == .tape {
                drawObject(object, image: nil, in: ctx)
            }
        }
    }
}
