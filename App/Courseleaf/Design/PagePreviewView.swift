import SwiftUI
import DocumentCore
import PageGeometry

// Live preview of a paper template, drawn from the same
// `PageGeometry.TemplateGeometry` primitives the editor and the exporters use,
// so what the student sees when choosing paper is what the page will be.

enum PagePreviewGeometry {
    /// Primitives for a template at a page size, in page points.
    static func primitives(for template: PaperTemplate, size: PageSize) -> [TemplatePrimitive] {
        TemplateGeometry.primitives(for: template, size: size)
    }

    /// Scale that fits a page of `pageSize` into `box` (aspect preserved).
    static func fitScale(pageSize: PageSize, in box: CGSize) -> Double {
        guard pageSize.isValid, box.width > 0, box.height > 0 else { return 1 }
        return min(Double(box.width) / pageSize.width, Double(box.height) / pageSize.height)
    }
}

/// A paper template rendered into the available space, with the page's aspect
/// ratio preserved.
struct PagePreviewView: View {
    var template: PaperTemplate
    var pageSize: PageSize
    var cornerRadius: CGFloat = 4
    /// Drawn behind the page so a preview reads as paper on any background.
    var showsShadow: Bool = true

    var body: some View {
        Canvas { context, size in
            // The closure's context is immutable; take a mutable copy to place
            // the page inside the box and draw into it.
            var canvas = context
            let scale = PagePreviewGeometry.fitScale(pageSize: pageSize, in: size)
            let width = pageSize.width * scale
            let height = pageSize.height * scale
            let originX = (Double(size.width) - width) / 2
            let originY = (Double(size.height) - height) / 2
            canvas.translateBy(x: originX, y: originY)
            for primitive in PagePreviewGeometry.primitives(for: template, size: pageSize) {
                draw(primitive, scale: scale, in: &canvas)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .background(Palette.paper)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 0.5)
        }
        .shadow(color: showsShadow ? Color.black.opacity(0.12) : .clear, radius: 3, x: 0, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(PaperKindNames.title(template.kind)) paper preview")
        .accessibilityValue(PaperKindNames.detail(template.kind))
    }

    private var aspectRatio: CGFloat {
        guard pageSize.isValid else { return 0.77 }
        return CGFloat(pageSize.width / pageSize.height)
    }

    private func draw(_ primitive: TemplatePrimitive, scale: Double, in context: inout GraphicsContext) {
        switch primitive {
        case .rect(let rect, let fill):
            let r = rect.standardized
            let cg = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
            context.fill(Path(cg), with: .color(Color(fill)))
        case .line(let from, let to, let width, let color):
            var path = Path()
            path.move(to: CGPoint(x: from.x * scale, y: from.y * scale))
            path.addLine(to: CGPoint(x: to.x * scale, y: to.y * scale))
            context.stroke(path, with: .color(Color(color)), lineWidth: max(0.35, width * scale))
        case .dot(let center, let radius, let color):
            let r = max(0.35, radius * scale)
            let rect = CGRect(x: center.x * scale - r, y: center.y * scale - r, width: 2 * r, height: 2 * r)
            context.fill(Path(ellipseIn: rect), with: .color(Color(color)))
        }
    }
}

/// Paper picker row: a preview plus the template's name and description.
struct PaperKindOption: View {
    var kind: PaperKind
    var pageSize: PageSize
    var isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            PagePreviewView(template: .preset(kind), pageSize: pageSize, showsShadow: false)
                .frame(width: 68, height: 88)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isSelected ? Palette.accent : .clear, lineWidth: 3)
                }
            Text(PaperKindNames.title(kind))
                .font(Typography.caption)
                .foregroundStyle(isSelected ? Palette.accent : Palette.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PaperKindNames.title(kind))
        .accessibilityHint(PaperKindNames.detail(kind))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
