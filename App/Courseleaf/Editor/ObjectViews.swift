import Foundation
import UIKit
import DocumentCore
import Editing

// One UIView per canvas object. A view's untransformed frame is the object's
// page-space frame (the page canvas is laid out at 1 point = 1 page point);
// rotation is applied about the frame centre through `transform`, exactly
// like `CanvasObject.transform`. Every object is an accessibility element.

@MainActor
class ObjectView: UIView {
    private(set) var object: CanvasObject
    /// True while a temporary preview (drag) frame is applied instead of `object`.
    private(set) var isPreviewing = false

    init(object: CanvasObject) {
        self.object = object
        super.init(frame: CGRect(object.frame))
        isAccessibilityElement = true
        isOpaque = false
        backgroundColor = .clear
        apply(object)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Applies the persisted object (frame, rotation, content).
    func apply(_ object: CanvasObject) {
        self.object = object
        isPreviewing = false
        layoutGeometry(frame: object.frame, rotation: object.rotation)
        contentDidChange()
        updateAccessibility()
    }

    /// Shows the object as it would look after `transform` (drag preview) without changing `object`.
    func preview(transformedBy transform: PageTransform?) {
        guard let transform else {
            if isPreviewing { isPreviewing = false; layoutGeometry(frame: object.frame, rotation: object.rotation) }
            return
        }
        let moved = DocumentEditor.transformed(object, by: transform)
        isPreviewing = true
        layoutGeometry(frame: moved.frame, rotation: moved.rotation)
    }

    func layoutGeometry(frame: PageRect, rotation: Double) {
        let f = CGRect(frame)
        transform = .identity
        bounds = CGRect(origin: .zero, size: f.size)
        center = CGPoint(x: f.midX, y: f.midY)
        transform = rotation == 0 ? .identity : CGAffineTransform(rotationAngle: rotation)
    }

    func contentDidChange() {}

    func updateAccessibility() {
        accessibilityLabel = Self.accessibilityLabel(for: object)
        accessibilityHint = object.isLocked ? "Locked" : nil
    }

    static func accessibilityLabel(for object: CanvasObject) -> String {
        switch object.content {
        case .text(let t): return t.text.isEmpty ? "Empty text box" : "Text: \(t.text)"
        case .image: return "Image"
        case .shape(let s): return "Shape: \(ShapeKindNames.name(s.kind))"
        case .tape(let t):
            let label = t.label.map { ", \($0)" } ?? ""
            return t.isRevealed ? "Tape, revealed\(label)" : "Tape, hidden\(label)"
        }
    }
}

// MARK: - Image

final class ImageObjectView: ObjectView {
    private let imageView = UIImageView()
    private var sourceImage: UIImage?
    private var croppedFor: PageRect?

    override init(object: CanvasObject) {
        super.init(object: object)
        imageView.contentMode = .scaleToFill
        imageView.clipsToBounds = true
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        accessibilityTraits = .image
        contentDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSourceImage(_ image: UIImage?) {
        sourceImage = image
        croppedFor = nil
        contentDidChange()
    }

    override func contentDidChange() {
        guard case .image(let content) = object.content else { return }
        alpha = CGFloat(content.opacity)
        guard let source = sourceImage else { imageView.image = nil; return }
        let crop = content.crop.standardized
        if croppedFor == crop, imageView.image != nil { return }
        croppedFor = crop
        if crop == .unit || crop.isEmpty {
            imageView.image = source
        } else if let cg = source.cgImage {
            let px = CGRect(x: crop.minX * CGFloat(cg.width), y: crop.minY * CGFloat(cg.height),
                            width: crop.width * CGFloat(cg.width), height: crop.height * CGFloat(cg.height))
            imageView.image = cg.cropping(to: px).map { UIImage(cgImage: $0, scale: source.scale, orientation: source.imageOrientation) } ?? source
        } else {
            imageView.image = source
        }
    }
}

// MARK: - Shape

final class ShapeObjectView: ObjectView {
    private let shapeLayer = CAShapeLayer()
    /// Extra hit slop around the stroke, in page points (scaled by the zoom by the caller).
    var hitTolerance: CGFloat = 8

    override init(object: CanvasObject) {
        super.init(object: object)
        layer.addSublayer(shapeLayer)
        contentDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds
        contentDidChange()
    }

    override func contentDidChange() {
        guard case .shape(let shape) = object.content else { return }
        let path = PageRenderer.shapePath(shape, in: bounds)
        shapeLayer.path = path.cgPath
        shapeLayer.strokeColor = CGColor.make(shape.strokeColor)
        shapeLayer.lineWidth = shape.strokeWidth
        shapeLayer.lineCap = .round
        shapeLayer.lineJoin = .round
        if let fill = shape.fillColor, shape.kind == .rectangle || shape.kind == .ellipse {
            shapeLayer.fillColor = CGColor.make(fill)
        } else {
            shapeLayer.fillColor = nil
        }
    }

    /// Only the stroked outline (plus tolerance) and any fill count as hits, so
    /// a large empty rectangle does not swallow writing inside it.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard case .shape(let shape) = object.content, let path = shapeLayer.path else { return false }
        if shape.fillColor != nil, path.contains(point) { return true }
        let width = max(shape.strokeWidth, 1) + hitTolerance * 2
        let outline = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return outline.contains(point)
    }
}

// MARK: - Tape

@MainActor
protocol TapeObjectViewDelegate: AnyObject {
    func tapeView(_ view: TapeObjectView, wantsRevealed revealed: Bool)
}

final class TapeObjectView: ObjectView {
    weak var delegate: TapeObjectViewDelegate?
    private let label = UILabel()

    override init(object: CanvasObject) {
        super.init(object: object)
        layer.cornerRadius = 4
        layer.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.textColor = UIColor.black.withAlphaComponent(0.7)
        label.frame = bounds.insetBy(dx: 4, dy: 2)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        accessibilityTraits = .button
        contentDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func contentDidChange() {
        guard case .tape(let tape) = object.content else { return }
        if tape.isRevealed {
            backgroundColor = .clear
            layer.borderWidth = 1.5
            layer.borderColor = CGColor.make(tape.color.withAlpha(0.9))
            label.isHidden = true
        } else {
            backgroundColor = UIColor(tape.color)
            layer.borderWidth = 0
            label.isHidden = false
            label.text = tape.label
        }
        accessibilityHint = tape.isRevealed ? "Double tap to hide the answer again" : "Double tap to reveal the answer"
    }

    @objc private func tapped() {
        guard case .tape(let tape) = object.content else { return }
        delegate?.tapeView(self, wantsRevealed: !tape.isRevealed)
    }
}

// MARK: - Text

@MainActor
protocol TextObjectViewDelegate: AnyObject {
    func textView(_ view: TextObjectView, didBeginEditing objectID: ObjectID)
    /// Called once when editing ends with the final text and the height that fits it.
    func textView(_ view: TextObjectView, didEndEditing objectID: ObjectID, text: String, fittingHeight: Double)
}

final class TextObjectView: ObjectView, UITextViewDelegate {
    weak var delegate: TextObjectViewDelegate?
    private let label = UILabel()
    private var editor: UITextView?
    var isEditing: Bool { editor != nil }

    override init(object: CanvasObject) {
        super.init(object: object)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.frame = bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
        accessibilityTraits = .staticText
        contentDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func contentDidChange() {
        guard case .text(let text) = object.content else { return }
        label.attributedText = PageRenderer.attributedString(for: text)
        if let editor, editor.text != text.text || editor.font != PageRenderer.font(for: text) {
            editor.font = PageRenderer.font(for: text)
            editor.textColor = UIColor(text.color)
            editor.textAlignment = PageRenderer.paragraphStyle(for: text).alignment
        }
        layer.borderWidth = text.text.isEmpty && editor == nil ? 1 : 0
        layer.borderColor = UIColor.systemGray3.cgColor
    }

    /// Height in page points needed for `text` at the current width.
    static func fittingHeight(for content: TextContent, width: Double) -> Double {
        let attributed = PageRenderer.attributedString(for: content)
        let rect = attributed.boundingRect(with: CGSize(width: max(width, 8), height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let lineHeight = PageRenderer.font(for: content).lineHeight
        return max(ceil(rect.height) + 8, lineHeight + 8)
    }

    func beginEditing() {
        guard editor == nil, case .text(let text) = object.content else { return }
        let textView = UITextView(frame: bounds)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        textView.font = PageRenderer.font(for: text)
        textView.textColor = UIColor(text.color)
        textView.textAlignment = PageRenderer.paragraphStyle(for: text).alignment
        textView.text = text.text
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        textView.textContainer.lineFragmentPadding = 2
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.systemBlue.cgColor
        textView.accessibilityLabel = "Text box editor"
        label.isHidden = true
        addSubview(textView)
        editor = textView
        textView.becomeFirstResponder()
        delegate?.textView(self, didBeginEditing: object.id)
    }

    func endEditing() {
        editor?.resignFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        // Grow the box while typing so the text is never clipped.
        guard case .text(var text) = object.content else { return }
        text.text = textView.text
        let needed = Self.fittingHeight(for: text, width: object.frame.width)
        if needed > bounds.height {
            var frame = object.frame
            frame.size.height = needed
            layoutGeometry(frame: frame, rotation: object.rotation)
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        let finalText = textView.text ?? ""
        textView.removeFromSuperview()
        editor = nil
        label.isHidden = false
        guard case .text(var text) = object.content else { return }
        text.text = finalText
        let height = Self.fittingHeight(for: text, width: object.frame.width)
        delegate?.textView(self, didEndEditing: object.id, text: finalText, fittingHeight: height)
    }
}
