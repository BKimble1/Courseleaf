import Foundation
import UIKit
import DocumentCore
import Editing

@MainActor
protocol ObjectLayerViewDelegate: AnyObject {
    func objectLayer(_ layer: ObjectLayerView, didTap objectID: ObjectID, tapCount: Int)
    func objectLayer(_ layer: ObjectLayerView, tapeWantsRevealed objectID: ObjectID, revealed: Bool)
    func objectLayer(_ layer: ObjectLayerView, textEditingBegan objectID: ObjectID)
    func objectLayer(_ layer: ObjectLayerView, textEditingEnded objectID: ObjectID, text: String, fittingHeight: Double)
}

/// Text, shape and tape objects, drawn above the ink layer (band 4). Tape is
/// always last so it covers what it should. Touch policy: tape is always
/// interactive; other objects only when `objectsInteractive` (lasso/text tool),
/// so a student can write over a text box with the pencil.
final class ObjectLayerView: UIView, TapeObjectViewDelegate, TextObjectViewDelegate {
    weak var delegate: ObjectLayerViewDelegate?
    private(set) var views: [ObjectID: ObjectView] = [:]
    private(set) var orderedIDs: [ObjectID] = []
    var objectsInteractive = false
    var isReadingMode = false
    var editingTextID: ObjectID? { views.values.compactMap { $0 as? TextObjectView }.first(where: \.isEditing)?.object.id }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(objects: [CanvasObject]) {
        let band = objects.filter { $0.kind != .image }
        let ids = Set(band.map(\.id))
        for (id, view) in views where !ids.contains(id) {
            (view as? TextObjectView)?.endEditing()
            view.removeFromSuperview()
            views[id] = nil
        }
        for object in band {
            if let view = views[object.id] {
                view.apply(object)
            } else {
                let view = makeView(for: object)
                views[object.id] = view
                addSubview(view)
            }
        }
        orderedIDs = band.filter { $0.kind != .tape }.map(\.id) + band.filter { $0.kind == .tape }.map(\.id)
        for id in orderedIDs { if let v = views[id] { bringSubviewToFront(v) } }
    }

    private func makeView(for object: CanvasObject) -> ObjectView {
        switch object.content {
        case .text:
            let view = TextObjectView(object: object)
            view.delegate = self
            return view
        case .shape:
            return ShapeObjectView(object: object)
        case .tape:
            let view = TapeObjectView(object: object)
            view.delegate = self
            return view
        case .image:
            return ObjectView(object: object) // never reached; images live in ImageObjectLayerView
        }
    }

    func view(for id: ObjectID) -> ObjectView? { views[id] }

    /// Top-most interactive object view under `point` (this view's coordinates).
    func objectID(at point: CGPoint) -> ObjectID? {
        for id in orderedIDs.reversed() {
            guard let view = views[id], !view.isHidden else { continue }
            let local = view.convert(point, from: self)
            if view.point(inside: local, with: nil) { return id }
        }
        return nil
    }

    func preview(ids: Set<ObjectID>, transform: PageTransform?) {
        for (id, view) in views where ids.contains(id) { view.preview(transformedBy: transform) }
    }

    func clearPreviews() { for view in views.values { view.preview(transformedBy: nil) } }

    func setShapeHitTolerance(_ tolerance: CGFloat) {
        for view in views.values { (view as? ShapeObjectView)?.hitTolerance = tolerance }
    }

    func beginEditingText(_ id: ObjectID) {
        (views[id] as? TextObjectView)?.beginEditing()
    }

    func endTextEditing() {
        for view in views.values { (view as? TextObjectView)?.endEditing() }
    }

    // MARK: Touch policy

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event), hit !== self else { return nil }
        if isReadingMode { return nil }
        if hit is TapeObjectView || hit.superview is TapeObjectView { return hit }
        if let text = hit as? UITextView, text.isFirstResponder { return hit }
        guard objectsInteractive else { return nil }
        if let objectView = hit as? ObjectView ?? hit.superview as? ObjectView, objectView.object.isLocked { return nil }
        return hit
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard objectsInteractive, let id = objectID(at: gesture.location(in: self)) else { return }
        delegate?.objectLayer(self, didTap: id, tapCount: 1)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard objectsInteractive, let id = objectID(at: gesture.location(in: self)) else { return }
        delegate?.objectLayer(self, didTap: id, tapCount: 2)
    }

    // MARK: TapeObjectViewDelegate / TextObjectViewDelegate

    func tapeView(_ view: TapeObjectView, wantsRevealed revealed: Bool) {
        guard !isReadingMode else { return }
        delegate?.objectLayer(self, tapeWantsRevealed: view.object.id, revealed: revealed)
    }

    func textView(_ view: TextObjectView, didBeginEditing objectID: ObjectID) {
        delegate?.objectLayer(self, textEditingBegan: objectID)
    }

    func textView(_ view: TextObjectView, didEndEditing objectID: ObjectID, text: String, fittingHeight: Double) {
        delegate?.objectLayer(self, textEditingEnded: objectID, text: text, fittingHeight: fittingHeight)
    }
}
