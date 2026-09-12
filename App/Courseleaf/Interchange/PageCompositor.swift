import Foundation
import CoreGraphics
import UIKit
import PencilKit
import DocumentCore
import PageGeometry

// Compositing of one page into a y-down CoreGraphics context whose origin is
// the page origin and whose unit is the page point (docs/ARCHITECTURE.md §3–4).
// The same routine draws PDF export pages (vector context), PNG/JPEG export
// (raster context) and the recognizer's input image, so what the student sees
// in export is what search recognizes.

/// Resolved background content of one page, ready to draw.
enum ExportBackground {
    case template(PaperTemplate)
    /// The source page (kept alive by its document) and the mapping that positions PDF user space under page space.
    case pdf(page: CGPDFPage, document: CGPDFDocument, mapping: PageMapping)
    /// Full-page image, aspect-fitted to the page.
    case image(CGImage)
}

/// Everything needed to draw one page, resolved from the document and its assets.
struct ExportPageInput: @unchecked Sendable {
    var page: Page
    var background: ExportBackground
    /// Decoded image objects by object ID (upright pixels).
    var images: [ObjectID: CGImage]
    /// Visible ink layers, decoded, in layer order.
    var inkDrawings: [PKDrawing]

    var pageSize: CGSize { IXGeometry.size(page.size) }
    var pageRect: CGRect { CGRect(origin: .zero, size: pageSize) }
}

/// Which bands to include. Export uses everything; the recognizer picks.
struct CompositeOptions {
    var tape: TapeExportPolicy = .asShown
    var inkRasterScale: Double = 2
    /// Draw the source PDF page as vector content (text stays selectable) instead of a raster snapshot.
    var preserveSourceVectors: Bool = true
    var includeBackground: Bool = true
    var includeImages: Bool = true
    var includeInk: Bool = true
    var includeObjects: Bool = true
    /// Template pages: draw only the paper colour, not the rules/dots (recognizer input).
    var suppressTemplateRules: Bool = false

    init(tape: TapeExportPolicy = .asShown, inkRasterScale: Double = 2, preserveSourceVectors: Bool = true) {
        self.tape = tape; self.inkRasterScale = inkRasterScale; self.preserveSourceVectors = preserveSourceVectors
    }
    init(_ options: ExportOptions) {
        self.init(tape: options.tape, inkRasterScale: options.inkRasterScale, preserveSourceVectors: options.preserveSourceVectors)
    }
}

enum PageCompositor {
    /// Draws the page back to front (background, image objects, ink, text/shape/tape)
    /// into `ctx`, clipped to the page rectangle. `ctx` must be a y-down context
    /// with the page origin at (0, 0) and one unit per page point (UIKit
    /// renderer contexts qualify; raster scale is carried by the context CTM).
    static func draw(_ input: ExportPageInput, in ctx: CGContext, options: CompositeOptions) {
        let pageRect = input.pageRect
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: pageRect)

        if options.includeBackground {
            drawBackground(input, in: ctx, options: options)
        } else {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(pageRect)
        }
        if options.includeImages {
            for object in ExportGeometry.objectsBelowInk(input.page.objects) {
                drawObject(object, image: input.images[object.id], in: ctx)
            }
        }
        if options.includeInk {
            drawInk(input.inkDrawings, pageRect: pageRect, scale: CGFloat(options.inkRasterScale), in: ctx)
        }
        if options.includeObjects {
            for object in ExportGeometry.objectsAboveInk(input.page.objects, tape: options.tape) {
                drawObject(object, image: nil, in: ctx)
            }
        }
    }

    // MARK: Background

    static func drawBackground(_ input: ExportPageInput, in ctx: CGContext, options: CompositeOptions) {
        let pageRect = input.pageRect
        switch input.background {
        case .template(let template):
            let primitives = TemplateGeometry.primitives(for: template, size: input.page.size)
            drawPrimitives(options.suppressTemplateRules ? Array(primitives.prefix(1)) : primitives, in: ctx)

        case .image(let image):
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(pageRect)
            let target = IXGeometry.fitted(imageSize: CGSize(width: image.width, height: image.height), in: pageRect)
            IXGeometry.drawImage(image, in: target, context: ctx)

        case .pdf(let page, _, let mapping):
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(pageRect)
            if options.preserveSourceVectors {
                drawSourcePage(page, mapping: mapping, in: ctx)
            } else if let raster = rasterizeSourcePage(page, mapping: mapping, scale: CGFloat(options.inkRasterScale)) {
                IXGeometry.drawImage(raster, in: pageRect, context: ctx)
            }
        }
    }

    /// Draws the source page's content stream as vectors. `CGContext.drawPDFPage`
    /// interprets the content in raw PDF user space (no `/Rotate`, no box
    /// translation), so the tested `PageMapping.pdfUserToPage` transform is
    /// concatenated first and the crop box is the clip (§3). Text drawn this way
    /// into a PDF context remains text.
    static func drawSourcePage(_ page: CGPDFPage, mapping: PageMapping, in ctx: CGContext) {
        ctx.saveGState()
        ctx.clip(to: IXGeometry.rect(mapping.pageBounds))
        ctx.concatenate(IXGeometry.transform(ExportGeometry.sourcePageTransform(mapping, orientation: .topLeftYDown, scale: 1)))
        ctx.clip(to: IXGeometry.rect(mapping.cropBox))
        ctx.interpolationQuality = .high
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    /// A raster snapshot of the source page at `scale` pixels per point (used when
    /// the caller asked not to preserve vectors).
    static func rasterizeSourcePage(_ page: CGPDFPage, mapping: PageMapping, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = max(scale, 0.25)
        format.opaque = true
        let size = IXGeometry.size(mapping.pageSize)
        guard size.width > 0, size.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { rendererContext in
            let ctx = rendererContext.cgContext
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            drawSourcePage(page, mapping: mapping, in: ctx)
        }
        return image.cgImage
    }

    static func drawPrimitives(_ primitives: [TemplatePrimitive], in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineCap(.butt)
        for primitive in primitives {
            switch primitive {
            case .rect(let rect, let fill):
                ctx.setFillColor(IXGeometry.cgColor(fill))
                ctx.fill(IXGeometry.rect(rect))
            case .line(let from, let to, let width, let color):
                ctx.setStrokeColor(IXGeometry.cgColor(color))
                ctx.setLineWidth(CGFloat(width))
                ctx.move(to: IXGeometry.point(from))
                ctx.addLine(to: IXGeometry.point(to))
                ctx.strokePath()
            case .dot(let center, let radius, let color):
                ctx.setFillColor(IXGeometry.cgColor(color))
                ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            }
        }
        ctx.restoreGState()
    }

    // MARK: Ink

    /// Rasterizes every visible ink layer over the page rectangle at `scale`
    /// pixels per point (`PKDrawing.image(from:scale:)`, public API) and draws the
    /// bitmap in page space. Rendering is forced to the light appearance so
    /// PencilKit's dark-mode colour adaptation never leaks into an export.
    /// The bitmap is composited normally, which is exactly how the transparent
    /// canvas view sits over the page on screen (marker translucency is inside
    /// the rendered strokes).
    static func drawInk(_ drawings: [PKDrawing], pageRect: CGRect, scale: CGFloat, in ctx: CGContext) {
        let scale = max(scale, 0.5)
        for drawing in drawings where !drawing.strokes.isEmpty {
            var image: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = drawing.image(from: pageRect, scale: scale)
            }
            guard let cg = image?.cgImage else { continue }
            IXGeometry.drawImage(cg, in: pageRect, context: ctx)
        }
    }

    // MARK: Objects

    /// Draws one object with its frame and rotation (about the frame centre).
    /// `image` is only used for image objects.
    static func drawObject(_ object: CanvasObject, image: CGImage?, in ctx: CGContext) {
        let frame = IXGeometry.rect(object.frame)
        guard frame.width > 0, frame.height > 0, frame.isFinite() else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if object.rotation != 0 {
            ctx.concatenate(IXGeometry.transform(.rotation(radians: object.rotation, about: object.frame.center)))
        }
        switch object.content {
        case .image(let content):
            guard let image else { return }
            drawImageObject(image, content: content, frame: frame, in: ctx)
        case .text(let content):
            drawText(content, frame: frame, in: ctx)
        case .shape(let content):
            drawShape(content, frame: frame, in: ctx)
        case .tape(let content):
            drawTape(content, frame: frame, in: ctx)
        }
    }

    static func drawImageObject(_ image: CGImage, content: ImageContent, frame: CGRect, in ctx: CGContext) {
        let crop = content.crop.standardized
        var source = image
        if crop != .unit {
            let px = CGRect(x: crop.minX * Double(image.width), y: crop.minY * Double(image.height),
                            width: crop.width * Double(image.width), height: crop.height * Double(image.height)).integral
            if let cropped = image.cropping(to: px) { source = cropped }
        }
        IXGeometry.drawImage(source, in: frame, context: ctx, alpha: CGFloat(min(max(content.opacity, 0), 1)))
    }

    /// Text is drawn through Core Text (`NSAttributedString.draw`), so in a PDF
    /// context it stays real, searchable text.
    static func drawText(_ content: TextContent, frame: CGRect, in ctx: CGContext) {
        let attributed = attributedString(for: content)
        ctx.saveGState()
        ctx.clip(to: frame)
        UIGraphicsPushContext(ctx)
        attributed.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    static func font(for content: TextContent) -> UIFont {
        let weight: UIFont.Weight
        switch content.weight {
        case .regular: weight = .regular
        case .medium: weight = .medium
        case .semibold: weight = .semibold
        case .bold: weight = .bold
        }
        let base = UIFont.systemFont(ofSize: CGFloat(max(content.fontSize, 1)), weight: weight)
        let design: UIFontDescriptor.SystemDesign
        switch content.design {
        case .standard: return base
        case .serif: design = .serif
        case .monospaced: design = .monospaced
        case .rounded: design = .rounded
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    static func attributedString(for content: TextContent) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        switch content.alignment {
        case .leading: paragraph.alignment = .natural
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: content.text, attributes: [
            .font: font(for: content),
            .foregroundColor: IXGeometry.uiColor(content.color),
            .paragraphStyle: paragraph,
        ])
    }

    static func shapePath(_ shape: ShapeContent, in frame: CGRect) -> CGPath {
        func point(_ unit: PagePoint) -> CGPoint {
            CGPoint(x: frame.minX + CGFloat(unit.x) * frame.width, y: frame.minY + CGFloat(unit.y) * frame.height)
        }
        let path = CGMutablePath()
        switch shape.kind {
        case .rectangle:
            path.addRect(frame)
        case .ellipse:
            path.addEllipse(in: frame)
        case .line:
            path.move(to: point(shape.start)); path.addLine(to: point(shape.end))
        case .arrow:
            let a = point(shape.start), b = point(shape.end)
            path.move(to: a); path.addLine(to: b)
            let length = hypot(b.x - a.x, b.y - a.y)
            if length > 0.001 {
                let head = min(max(CGFloat(shape.strokeWidth) * 4 + 6, 8), length)
                let angle = atan2(b.y - a.y, b.x - a.x)
                let spread: CGFloat = .pi / 7
                let left = CGPoint(x: b.x - head * cos(angle - spread), y: b.y - head * sin(angle - spread))
                let right = CGPoint(x: b.x - head * cos(angle + spread), y: b.y - head * sin(angle + spread))
                path.move(to: left); path.addLine(to: b); path.addLine(to: right)
            }
        }
        return path
    }

    static func drawShape(_ content: ShapeContent, frame: CGRect, in ctx: CGContext) {
        let path = shapePath(content, in: frame)
        if let fill = content.fillColor, content.kind == .rectangle || content.kind == .ellipse {
            ctx.setFillColor(IXGeometry.cgColor(fill))
            ctx.addPath(path)
            ctx.fillPath()
        }
        if content.strokeWidth > 0 {
            ctx.setStrokeColor(IXGeometry.cgColor(content.strokeColor))
            ctx.setLineWidth(CGFloat(content.strokeWidth))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    /// An opaque cover; the optional label is centred in a contrasting colour.
    static func drawTape(_ content: TapeContent, frame: CGRect, in ctx: CGContext) {
        ctx.setFillColor(IXGeometry.cgColor(content.color.withAlpha(1)))
        ctx.fill(frame)
        guard let label = content.label, !label.isEmpty else { return }
        let luminance = 0.2126 * content.color.red + 0.7152 * content.color.green + 0.0722 * content.color.blue
        let labelColor: UIColor = luminance > 0.55 ? UIColor(white: 0.15, alpha: 1) : .white
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let font = UIFont.systemFont(ofSize: min(max(frame.height * 0.4, 8), 14), weight: .medium)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: labelColor, .paragraphStyle: paragraph])
        let height = font.lineHeight
        let rect = CGRect(x: frame.minX + 4, y: frame.midY - height / 2, width: frame.width - 8, height: height)
        ctx.saveGState()
        ctx.clip(to: frame)
        UIGraphicsPushContext(ctx)
        text.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
        UIGraphicsPopContext()
        ctx.restoreGState()
    }
}

private extension CGRect {
    func isFinite() -> Bool { minX.isFinite && minY.isFinite && width.isFinite && height.isFinite }
}
