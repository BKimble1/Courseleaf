import SwiftUI
import DocumentCore

// Original procedural notebook covers. Every `CoverStyle.Palette` x
// `CoverStyle.Pattern` combination is drawn from the geometry in `CoverArt`
// with SwiftUI `Canvas`; no cover images are shipped or copied from any other
// app. The same geometry is used by the tests, so a cover can be checked
// without rendering pixels.

enum CoverArt {
    /// One drawing instruction of a cover, in unit coordinates (0...1 of the
    /// cover's width and height), back to front.
    enum Mark: Hashable {
        case fill(RGBAColor)
        case rect(x: Double, y: Double, width: Double, height: Double, color: RGBAColor)
        case circle(x: Double, y: Double, radius: Double, color: RGBAColor)
        case line(x1: Double, y1: Double, x2: Double, y2: Double, width: Double, color: RGBAColor)
    }

    /// Spine width as a fraction of the cover width.
    static let spineWidth: Double = 0.12

    /// Every mark of a cover, back to front. Always at least the background
    /// fill and the spine, for every palette and pattern.
    static func marks(for style: CoverStyle) -> [Mark] {
        let tones = Palette.tones(for: style.palette)
        var marks: [Mark] = [.fill(tones.base)]
        switch style.pattern {
        case .plain:
            marks.append(.rect(x: 0.18, y: 0.08, width: 0.7, height: 0.84, color: tones.light.withAlpha(0.12)))
        case .bands:
            var y = 0.14
            while y < 0.92 {
                marks.append(.rect(x: 0.18, y: y, width: 0.72, height: 0.035, color: tones.light.withAlpha(0.35)))
                y += 0.12
            }
        case .dots:
            var y = 0.12
            while y < 0.94 {
                var x = 0.22
                while x < 0.94 {
                    marks.append(.circle(x: x, y: y, radius: 0.018, color: tones.light.withAlpha(0.45)))
                    x += 0.12
                }
                y += 0.1
            }
        case .weave:
            var x = 0.16
            while x < 0.96 {
                marks.append(.line(x1: x, y1: 0.04, x2: x, y2: 0.96, width: 0.008, color: tones.light.withAlpha(0.28)))
                x += 0.1
            }
            var y = 0.06
            while y < 0.96 {
                marks.append(.line(x1: 0.14, y1: y, x2: 0.98, y2: y, width: 0.008, color: tones.deep.withAlpha(0.3)))
                y += 0.1
            }
        }
        // Spine and edge highlight, drawn last so the pattern never covers them.
        marks.append(.rect(x: 0, y: 0, width: spineWidth, height: 1, color: tones.deep))
        marks.append(.line(x1: spineWidth, y1: 0, x2: spineWidth, y2: 1, width: 0.006, color: tones.light.withAlpha(0.6)))
        return marks
    }

    /// Title colour for a cover.
    static func labelColor(for style: CoverStyle) -> RGBAColor { Palette.tones(for: style.palette).label }

    /// Every cover a student can pick, in a stable order.
    static var allStyles: [CoverStyle] {
        CoverStyle.Palette.allCases.flatMap { palette in
            CoverStyle.Pattern.allCases.map { CoverStyle(palette: palette, pattern: $0) }
        }
    }
}

/// Draws a cover. `title` is shown when the style asks for it.
struct CoverView: View {
    var style: CoverStyle
    var title: String?
    var cornerRadius: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            // The closure's context is immutable; the drawing helpers need a
            // mutable copy (GraphicsContext is a value type).
            var canvas = context
            for mark in CoverArt.marks(for: style) {
                draw(mark, in: &canvas, size: size)
            }
        }
        .overlay(alignment: .topLeading) { titleOverlay }
        .background(Color(Palette.tones(for: style.palette).base))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var titleOverlay: some View {
        if style.showsTitle, let title, !title.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(CoverArt.labelColor(for: style)))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(.leading, 18)
                .padding(.trailing, 10)
                .padding(.top, 14)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityDescription: String {
        let base = "\(Palette.name(for: style.palette)) cover, \(Palette.name(for: style.pattern)) pattern"
        if style.showsTitle, let title, !title.isEmpty { return "\(base), titled \(title)" }
        return base
    }

    private func draw(_ mark: CoverArt.Mark, in context: inout GraphicsContext, size: CGSize) {
        switch mark {
        case .fill(let color):
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(color)))
        case .rect(let x, let y, let width, let height, let color):
            let rect = CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
            context.fill(Path(rect), with: .color(Color(color)))
        case .circle(let x, let y, let radius, let color):
            let r = radius * min(size.width, size.height)
            let rect = CGRect(x: x * size.width - r, y: y * size.height - r, width: 2 * r, height: 2 * r)
            context.fill(Path(ellipseIn: rect), with: .color(Color(color)))
        case .line(let x1, let y1, let x2, let y2, let width, let color):
            var path = Path()
            path.move(to: CGPoint(x: x1 * size.width, y: y1 * size.height))
            path.addLine(to: CGPoint(x: x2 * size.width, y: y2 * size.height))
            context.stroke(path, with: .color(Color(color)), lineWidth: max(0.5, width * size.width))
        }
    }
}

/// A small swatch used in cover pickers and folder colour menus.
struct CoverSwatch: View {
    var style: CoverStyle
    var isSelected: Bool

    var body: some View {
        CoverView(style: style, title: nil, cornerRadius: 6)
            .frame(width: 44, height: 58)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Palette.accent : .clear, lineWidth: 3)
            }
            .accessibilityLabel("\(Palette.name(for: style.palette)) \(Palette.name(for: style.pattern))")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
