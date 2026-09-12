import Foundation
import UIKit
import DocumentCore

/// Resize/rotate handles around a selection.
enum SelectionHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, rotate

    var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
    var accessibilityName: String {
        switch self {
        case .topLeft: return "top left"
        case .top: return "top"
        case .topRight: return "top right"
        case .right: return "right"
        case .bottomRight: return "bottom right"
        case .bottom: return "bottom"
        case .bottomLeft: return "bottom left"
        case .left: return "left"
        case .rotate: return "rotate"
        }
    }
}

@MainActor
protocol SelectionOverlayDelegate: AnyObject {
    /// Whether the overlay should take a touch at `point` (page space). Called
    /// for points outside the selection bounds and handles.
    func overlay(_ overlay: SelectionOverlayView, shouldBeginInteractionAt point: CGPoint) -> Bool
    func overlay(_ overlay: SelectionOverlayView, panBeganAt point: CGPoint, handle: SelectionHandle?)
    func overlay(_ overlay: SelectionOverlayView, panMovedTo point: CGPoint)
    func overlay(_ overlay: SelectionOverlayView, panEndedAt point: CGPoint, cancelled: Bool)
    func overlay(_ overlay: SelectionOverlayView, tappedAt point: CGPoint)
    func overlay(_ overlay: SelectionOverlayView, longPressedAt point: CGPoint)
}

/// The topmost page layer: draws the lasso path, marquee, selection bounds
/// with handles, shape/tape creation previews and search highlights, and
/// routes single-touch pans/taps to the selection controller. Everything is
/// in page space; on-screen sizes are divided by `displayZoom` so handles and
/// line widths stay constant while zooming.
final class SelectionOverlayView: UIView, UIGestureRecognizerDelegate {
    weak var delegate: SelectionOverlayDelegate?

    var displayZoom: CGFloat = 1 { didSet { if displayZoom != oldValue { setNeedsDisplay() } } }
    /// Free-form lasso path while dragging.
    var lassoPoints: [CGPoint] = [] { didSet { setNeedsDisplay() } }
    var marqueeRect: CGRect? { didSet { setNeedsDisplay() } }
    /// Bounds of the current selection (page space); nil hides everything.
    var selectionBounds: CGRect? { didSet { setNeedsDisplay(); updateAccessibility() } }
    var showsHandles = true { didSet { setNeedsDisplay() } }
    var canRotate = true { didSet { setNeedsDisplay() } }
    var canResize = true { didSet { setNeedsDisplay() } }
    /// Transient highlight (search hit, review region).
    var highlightRect: CGRect? { didSet { setNeedsDisplay() } }
    var creationPreview: (shape: ShapeContent?, frame: CGRect)? { didSet { setNeedsDisplay() } }
    /// Taken by the controller: true when the active tool needs the overlay for drags (lasso/shape/tape/text).
    var acceptsDrags = false
    var isReadingMode = false

    private let pan = UIPanGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private let longPress = UILongPressGestureRecognizer()
    private var activeHandle: SelectionHandle?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        pan.maximumNumberOfTouches = 1
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.delegate = self
        tap.addTarget(self, action: #selector(handleTap(_:)))
        tap.delegate = self
        longPress.minimumPressDuration = 0.45
        longPress.addTarget(self, action: #selector(handleLongPress(_:)))
        longPress.delegate = self
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
        addGestureRecognizer(longPress)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Geometry

    var handleRadius: CGFloat { 9 / max(displayZoom, 0.01) }
    var handleHitRadius: CGFloat { 22 / max(displayZoom, 0.01) }
    var rotateHandleOffset: CGFloat { 36 / max(displayZoom, 0.01) }

    func handlePosition(_ handle: SelectionHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .rotate: return CGPoint(x: rect.midX, y: rect.minY - rotateHandleOffset)
        }
    }

    func handle(at point: CGPoint) -> SelectionHandle? {
        guard let rect = selectionBounds, showsHandles else { return nil }
        var best: (SelectionHandle, CGFloat)?
        for handle in SelectionHandle.allCases {
            if handle == .rotate && !canRotate { continue }
            if handle != .rotate && !canResize { continue }
            let p = handlePosition(handle, in: rect)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= handleHitRadius, best == nil || d < best!.1 { best = (handle, d) }
        }
        return best?.0
    }

    func isInsideSelection(_ point: CGPoint) -> Bool {
        guard let rect = selectionBounds else { return false }
        return rect.insetBy(dx: -handleHitRadius / 2, dy: -handleHitRadius / 2).contains(point)
    }

    // MARK: Touch routing

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isReadingMode, bounds.contains(point) else { return nil }
        if handle(at: point) != nil || isInsideSelection(point) { return self }
        guard acceptsDrags, let delegate else { return nil }
        return delegate.overlay(self, shouldBeginInteractionAt: point) ? self : nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Let the scroll view's pinch run alongside so a second finger still zooms.
        other is UIPinchGestureRecognizer
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            activeHandle = handle(at: point)
            delegate?.overlay(self, panBeganAt: point, handle: activeHandle)
        case .changed:
            delegate?.overlay(self, panMovedTo: point)
        case .ended:
            delegate?.overlay(self, panEndedAt: point, cancelled: false)
            activeHandle = nil
        case .cancelled, .failed:
            delegate?.overlay(self, panEndedAt: point, cancelled: true)
            activeHandle = nil
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        delegate?.overlay(self, tappedAt: gesture.location(in: self))
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        delegate?.overlay(self, longPressedAt: gesture.location(in: self))
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let z = max(displayZoom, 0.01)
        let accent = UIColor.systemBlue
        if let highlight = highlightRect {
            ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(0.35).cgColor)
            ctx.fill(highlight)
            ctx.setStrokeColor(UIColor.systemYellow.cgColor)
            ctx.setLineWidth(2 / z)
            ctx.stroke(highlight)
        }
        if lassoPoints.count > 1 {
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5 / z)
            ctx.setLineDash(phase: 0, lengths: [6 / z, 4 / z])
            ctx.move(to: lassoPoints[0])
            for p in lassoPoints.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if let marquee = marqueeRect {
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.fill(marquee)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1 / z)
            ctx.setLineDash(phase: 0, lengths: [6 / z, 4 / z])
            ctx.stroke(marquee)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if let preview = creationPreview {
            let frame = preview.frame.standardized
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1 / z)
            if let shape = preview.shape {
                let path = PageRenderer.shapePath(shape, in: frame)
                ctx.setStrokeColor(CGColor.make(shape.strokeColor))
                ctx.setLineWidth(shape.strokeWidth)
                ctx.setLineCap(.round); ctx.setLineJoin(.round)
                ctx.addPath(path.cgPath); ctx.strokePath()
            } else {
                ctx.setLineDash(phase: 0, lengths: [5 / z, 3 / z])
                ctx.stroke(frame)
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
        if let selection = selectionBounds {
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5 / z)
            ctx.setLineDash(phase: 0, lengths: [5 / z, 3 / z])
            ctx.stroke(selection)
            ctx.setLineDash(phase: 0, lengths: [])
            guard showsHandles else { return }
            let r = handleRadius
            for handle in SelectionHandle.allCases {
                if handle == .rotate && !canRotate { continue }
                if handle != .rotate && !canResize { continue }
                let p = handlePosition(handle, in: selection)
                if handle == .rotate {
                    ctx.setStrokeColor(accent.cgColor)
                    ctx.setLineWidth(1 / z)
                    ctx.move(to: CGPoint(x: selection.midX, y: selection.minY))
                    ctx.addLine(to: p)
                    ctx.strokePath()
                }
                let circle = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fillEllipse(in: circle)
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(1.5 / z)
                ctx.strokeEllipse(in: circle)
            }
        }
    }

    private func updateAccessibility() {
        if selectionBounds != nil {
            isAccessibilityElement = true
            accessibilityLabel = "Selection"
            accessibilityHint = "Drag to move. Double tap and hold for actions."
        } else {
            isAccessibilityElement = false
        }
    }
}
