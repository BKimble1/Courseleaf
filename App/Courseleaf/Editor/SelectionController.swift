import Foundation
import UIKit
import PencilKit
import DocumentCore
import PageGeometry
import Editing
import Workspace

// App-owned lasso selection (docs/ARCHITECTURE.md §5): objects are hit-tested
// through `Editing.SelectionRules`, ink through `PencilKitDrawing.strokeIndices`.
// Move/resize/rotate preview live and commit as one grouped operation
// (`transformObjects` + `replaceInk`), so a mixed selection undoes in one
// step (A09). Only actions from `SelectionRules.availableActions` are offered.

@MainActor
protocol SelectionControllerHost: AnyObject {
    var session: any DocumentSessioning { get }
    var toolState: EditorToolState { get set }
    var displayZoom: CGFloat { get }
    var screenScale: CGFloat { get }
    func canvas(for pageID: PageID) -> PageCanvasView?
    /// Runs `body` as one undoable document operation (grouped, registered with the shared undo manager).
    func performDocumentOperation(_ name: String, _ body: () throws -> Void)
    /// Registers a drawing as a new ink asset; nil when the drawing is empty.
    func registerInkAsset(_ drawing: PKDrawing) -> AssetID?
    /// Registers image bytes as an asset (deduplicated by digest inside Persistence).
    func registerImageAsset(data: Data, mediaType: AssetMediaType) -> AssetID
    func presentColorPicker(anchor: UIView, anchorRect: CGRect, current: RGBAColor, completion: @escaping (RGBAColor) -> Void)
    func presentImageCrop(pageID: PageID, object: CanvasObject)
    func selectionDidChange(_ selection: Selection?)
}

@MainActor
final class SelectionController: NSObject, SelectionOverlayDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    weak var host: SelectionControllerHost?
    private(set) var selection: Selection?
    private var selectionObjectBounds: PageRect?

    private enum Drag {
        case none
        case lasso([CGPoint])
        case marquee(start: CGPoint)
        case create(start: CGPoint)
        case move(start: CGPoint)
        case resize(handle: SelectionHandle, initial: CGRect)
        case rotate(center: CGPoint, startAngle: CGFloat)
    }
    private var drag: Drag = .none
    private var dragTransform: PageTransform = .identity
    private var draggedInkOriginal: PKDrawing?
    private var draggedInkIndices: [Int] = []
    private var dragBoundsBeforeDrag: CGRect?
    private var menuInteractions: [ObjectIdentifier: UIEditMenuInteraction] = [:]

    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        super.init()
    }

    // MARK: Canvas registration

    func attach(to canvas: PageCanvasView) {
        canvas.overlay.delegate = self
        if menuInteractions[ObjectIdentifier(canvas)] == nil {
            let interaction = UIEditMenuInteraction(delegate: self)
            canvas.overlay.addInteraction(interaction)
            menuInteractions[ObjectIdentifier(canvas)] = interaction
        }
    }

    func detach(from canvas: PageCanvasView) {
        if selection?.pageID == canvas.pageID { clearSelection() }
        if let interaction = menuInteractions.removeValue(forKey: ObjectIdentifier(canvas)) {
            canvas.overlay.removeInteraction(interaction)
        }
        if canvas.overlay.delegate === self { canvas.overlay.delegate = nil }
    }

    // MARK: Selection state

    private var currentCanvas: PageCanvasView? {
        guard let selection else { return nil }
        return host?.canvas(for: selection.pageID)
    }

    private var currentPage: Page? {
        guard let selection else { return nil }
        return host?.session.editor.page(selection.pageID)
    }

    func clearSelection() {
        guard selection != nil else { return }
        if let canvas = currentCanvas {
            canvas.overlay.selectionBounds = nil
            canvas.objectLayer.clearPreviews()
            canvas.imageLayer.clearPreviews()
        }
        selection = nil
        host?.selectionDidChange(nil)
    }

    func select(_ newSelection: Selection) {
        if let old = selection, old.pageID != newSelection.pageID { clearSelection() }
        selection = newSelection.isEmpty ? nil : newSelection
        refreshOverlay()
        host?.selectionDidChange(selection)
    }

    func selectObject(_ id: ObjectID, on pageID: PageID) {
        select(Selection(pageID: pageID, objectIDs: [id]))
    }

    /// Recomputes selection bounds from the document (after a change or undo).
    func refreshAfterDocumentChange(changedPageIDs: Set<PageID>) {
        guard let selection, changedPageIDs.contains(selection.pageID) else { return }
        guard let page = host?.session.editor.page(selection.pageID) else { clearSelection(); return }
        let existing = selection.objectIDs.filter { page.object($0) != nil }
        var updated = selection
        updated.objectIDs = existing
        if let canvas = currentCanvas {
            let count = canvas.drawing.strokes.count
            updated.strokeIndices = updated.strokeIndices.mapValues { $0.filter { $0 < count } }
        }
        self.selection = updated.isEmpty ? nil : updated
        refreshOverlay()
        host?.selectionDidChange(self.selection)
    }

    private func inkBounds(for selection: Selection, canvas: PageCanvasView) -> PageRect? {
        guard selection.hasInk else { return nil }
        let drawing = PencilKitDrawing(drawing: canvas.drawing)
        let indices = selection.strokeIndices.values.flatMap { $0 }
        return drawing.bounds(ofStrokes: indices)
    }

    func selectionBounds() -> PageRect? {
        guard let selection, let page = currentPage, let canvas = currentCanvas else { return nil }
        return SelectionRules.bounds(of: selection, in: page, inkBounds: inkBounds(for: selection, canvas: canvas))
    }

    func availableActions() -> Set<SelectionAction> {
        guard let selection, let page = currentPage else { return [.paste] }
        return SelectionRules.availableActions(for: selection, in: page)
    }

    private func refreshOverlay() {
        guard let canvas = currentCanvas else { return }
        if let bounds = selectionBounds() {
            let actions = availableActions()
            canvas.overlay.selectionBounds = CGRect(bounds)
            canvas.overlay.showsHandles = actions.contains(.move)
            canvas.overlay.canResize = actions.contains(.resize)
            canvas.overlay.canRotate = actions.contains(.rotate)
        } else {
            canvas.overlay.selectionBounds = nil
        }
    }

    // MARK: SelectionOverlayDelegate

    private func canvas(of overlay: SelectionOverlayView) -> PageCanvasView? {
        overlay.superview as? PageCanvasView
    }

    func overlay(_ overlay: SelectionOverlayView, shouldBeginInteractionAt point: CGPoint) -> Bool {
        guard let canvas = canvas(of: overlay) else { return false }
        // Text/shape/tape objects handle their own taps when interactive; the overlay takes the rest.
        return canvas.objectLayer.objectID(at: point) == nil
    }

    func overlay(_ overlay: SelectionOverlayView, panBeganAt point: CGPoint, handle: SelectionHandle?) {
        guard let canvas = canvas(of: overlay), let host else { return }
        let tool = host.toolState.tool
        canvas.objectLayer.endTextEditing()
        if let selection, selection.pageID == canvas.pageID, let bounds = overlay.selectionBounds {
            let actions = availableActions()
            if let handle {
                if handle == .rotate, actions.contains(.rotate) {
                    let center = CGPoint(x: bounds.midX, y: bounds.midY)
                    drag = .rotate(center: center, startAngle: atan2(point.y - center.y, point.x - center.x))
                    beginTransformPreview(canvas: canvas)
                    return
                }
                if handle != .rotate, actions.contains(.resize) {
                    drag = .resize(handle: handle, initial: bounds)
                    beginTransformPreview(canvas: canvas)
                    return
                }
            }
            if overlay.isInsideSelection(point), actions.contains(.move) {
                drag = .move(start: point)
                beginTransformPreview(canvas: canvas)
                return
            }
        }
        switch tool {
        case .lasso:
            let page = host.session.editor.page(canvas.pageID)
            if let page, let hit = SelectionRules.object(in: page, at: PagePoint(point)) {
                // Dragging an unselected object moves it directly.
                selectObject(hit, on: canvas.pageID)
                if availableActions().contains(.move) {
                    drag = .move(start: point)
                    beginTransformPreview(canvas: canvas)
                }
                return
            }
            clearSelection()
            switch host.toolState.lassoMode {
            case .freehand: drag = .lasso([point]); overlay.lassoPoints = [point]
            case .rectangle: drag = .marquee(start: point); overlay.marqueeRect = CGRect(origin: point, size: .zero)
            }
        case .shape, .tape, .text:
            clearSelection()
            drag = .create(start: point)
            overlay.creationPreview = (shape: creationShape(for: tool), frame: CGRect(origin: point, size: .zero))
        default:
            drag = .none
        }
    }

    func overlay(_ overlay: SelectionOverlayView, panMovedTo point: CGPoint) {
        guard let canvas = canvas(of: overlay) else { return }
        switch drag {
        case .lasso(var points):
            points.append(point)
            drag = .lasso(points)
            overlay.lassoPoints = points
        case .marquee(let start):
            overlay.marqueeRect = rect(from: start, to: point)
        case .create(let start):
            let tool = host?.toolState.tool ?? .lasso
            overlay.creationPreview = (shape: creationShape(for: tool, from: start, to: point), frame: rect(from: start, to: point))
        case .move(let start):
            updateTransformPreview(.translation(x: Double(point.x - start.x), y: Double(point.y - start.y)), canvas: canvas)
        case .resize(let handle, let initial):
            updateTransformPreview(Self.resizeTransform(handle: handle, initial: initial, point: point), canvas: canvas)
        case .rotate(let center, let startAngle):
            let angle = atan2(point.y - center.y, point.x - center.x) - startAngle
            updateTransformPreview(.rotation(radians: Double(angle), about: PagePoint(center)), canvas: canvas)
        case .none:
            break
        }
    }

    func overlay(_ overlay: SelectionOverlayView, panEndedAt point: CGPoint, cancelled: Bool) {
        guard let canvas = canvas(of: overlay), let host else { drag = .none; return }
        defer { drag = .none }
        switch drag {
        case .lasso(var points):
            points.append(point)
            overlay.lassoPoints = []
            guard !cancelled, points.count >= 3 else { return }
            finishLasso(polygon: points.map(PagePoint.init), rect: nil, canvas: canvas)
        case .marquee(let start):
            overlay.marqueeRect = nil
            guard !cancelled else { return }
            finishLasso(polygon: nil, rect: PageRect(rect(from: start, to: point)), canvas: canvas)
        case .create(let start):
            overlay.creationPreview = nil
            guard !cancelled else { return }
            createObject(tool: host.toolState.tool, from: start, to: point, canvas: canvas)
        case .move, .resize, .rotate:
            if cancelled || dragTransform.isApproximatelyEqual(to: .identity, tolerance: 1e-6) {
                cancelTransformPreview(canvas: canvas)
            } else {
                commitTransform(dragTransform, canvas: canvas)
            }
        case .none:
            break
        }
    }

    func overlay(_ overlay: SelectionOverlayView, tappedAt point: CGPoint) {
        guard let canvas = canvas(of: overlay), let host else { return }
        canvas.objectLayer.endTextEditing()
        switch host.toolState.tool {
        case .text:
            if let page = host.session.editor.page(canvas.pageID), let hit = SelectionRules.object(in: page, at: PagePoint(point)),
               page.object(hit)?.kind == .text {
                selectObject(hit, on: canvas.pageID)
                canvas.objectLayer.beginEditingText(hit)
            } else {
                createTextBox(at: point, size: nil, canvas: canvas)
            }
        case .lasso:
            if let page = host.session.editor.page(canvas.pageID), let hit = SelectionRules.object(in: page, at: PagePoint(point)) {
                selectObject(hit, on: canvas.pageID)
                presentMenu(on: canvas, at: point)
            } else if let selection, selection.pageID == canvas.pageID, overlay.isInsideSelection(point) {
                presentMenu(on: canvas, at: point)
            } else {
                clearSelection()
            }
        default:
            break
        }
    }

    func overlay(_ overlay: SelectionOverlayView, longPressedAt point: CGPoint) {
        guard let canvas = canvas(of: overlay) else { return }
        if let selection, selection.pageID == canvas.pageID, overlay.isInsideSelection(point) {
            presentMenu(on: canvas, at: point)
        } else if let page = host?.session.editor.page(canvas.pageID), let hit = SelectionRules.object(in: page, at: PagePoint(point)) {
            selectObject(hit, on: canvas.pageID)
            presentMenu(on: canvas, at: point)
        } else {
            clearSelection()
            presentMenu(on: canvas, at: point)   // paste / add to review
        }
    }

    /// Object tap from the object layer (text/shape when the lasso or text tool is active).
    func objectTapped(_ id: ObjectID, on canvas: PageCanvasView, tapCount: Int) {
        guard let host, let page = host.session.editor.page(canvas.pageID), let object = page.object(id) else { return }
        if object.isLocked {
            selectObject(id, on: canvas.pageID)
            return
        }
        selectObject(id, on: canvas.pageID)
        if object.kind == .text, tapCount == 2 || host.toolState.tool == .text {
            canvas.objectLayer.beginEditingText(id)
        } else if tapCount == 1 {
            presentMenu(on: canvas, at: CGPoint(object.bounds.center))
        }
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // MARK: Lasso

    private func finishLasso(polygon: [PagePoint]?, rect: PageRect?, canvas: PageCanvasView) {
        guard let host, let page = host.session.editor.page(canvas.pageID) else { return }
        let filter = host.toolState.selectionFilter
        var objectIDs: [ObjectID] = []
        var strokes: [Int] = []
        let drawing = PencilKitDrawing(drawing: canvas.drawing)
        if let polygon {
            objectIDs = SelectionRules.objects(in: page, inside: polygon, filter: filter)
            if filter.contains(.ink) { strokes = drawing.strokeIndices(inside: polygon) }
        } else if let rect {
            objectIDs = SelectionRules.objects(in: page, intersecting: rect, filter: filter)
            if filter.contains(.ink) { strokes = drawing.strokeIndices(intersecting: rect) }
        }
        var strokeMap: [InkLayerID: [Int]] = [:]
        if let layer = canvas.inkLayerID, !strokes.isEmpty { strokeMap[layer] = strokes }
        let newSelection = Selection(pageID: canvas.pageID, objectIDs: Set(objectIDs), strokeIndices: strokeMap)
        guard !newSelection.isEmpty else { clearSelection(); return }
        select(newSelection)
        if let bounds = canvas.overlay.selectionBounds {
            presentMenu(on: canvas, at: CGPoint(x: bounds.midX, y: bounds.minY))
        }
    }

    // MARK: Transform preview and commit

    private func beginTransformPreview(canvas: PageCanvasView) {
        guard let selection else { return }
        dragTransform = .identity
        dragBoundsBeforeDrag = canvas.overlay.selectionBounds
        draggedInkIndices = selection.strokeIndices.values.flatMap { $0 }
        if !draggedInkIndices.isEmpty {
            draggedInkOriginal = canvas.drawing
            _ = canvas.beginInkPreview(strokeIndices: draggedInkIndices, screenScale: host?.screenScale ?? 2, zoom: host?.displayZoom ?? 1)
        } else {
            draggedInkOriginal = nil
        }
    }

    private func updateTransformPreview(_ transform: PageTransform, canvas: PageCanvasView) {
        guard let selection else { return }
        dragTransform = transform
        canvas.objectLayer.preview(ids: selection.objectIDs, transform: transform)
        canvas.imageLayer.preview(ids: selection.objectIDs, transform: transform)
        if !draggedInkIndices.isEmpty { canvas.updateInkPreview(transform: transform) }
        if let before = dragBoundsBeforeDrag {
            canvas.overlay.selectionBounds = CGRect(PageRect(before).applying(transform))
        }
    }

    private func cancelTransformPreview(canvas: PageCanvasView) {
        canvas.objectLayer.clearPreviews()
        canvas.imageLayer.clearPreviews()
        if let original = draggedInkOriginal { canvas.restoreDrawingAfterCancelledPreview(original) } else { canvas.endInkPreview() }
        draggedInkOriginal = nil
        draggedInkIndices = []
        canvas.overlay.selectionBounds = dragBoundsBeforeDrag
        dragBoundsBeforeDrag = nil
        dragTransform = .identity
    }

    private func commitTransform(_ transform: PageTransform, canvas: PageCanvasView) {
        guard let host, let selection else { cancelTransformPreview(canvas: canvas); return }
        let original = draggedInkOriginal
        let indices = draggedInkIndices
        canvas.objectLayer.clearPreviews()
        canvas.imageLayer.clearPreviews()
        canvas.endInkPreview()
        draggedInkOriginal = nil
        draggedInkIndices = []
        dragBoundsBeforeDrag = nil
        let name = Self.operationName(for: transform)
        host.performDocumentOperation(name) {
            let objectIDs = Array(selection.objectIDs)
            if !objectIDs.isEmpty {
                try host.session.apply(.transformObjects(selection.pageID, objectIDs, transform))
            }
            if let original, !indices.isEmpty, let layerID = canvas.inkLayerID {
                let moved = PencilKitDrawing(drawing: original).transformingStrokes(indices, by: transform)
                let assetID = host.registerInkAsset(moved.drawing)
                canvas.setDrawing(moved.drawing, assetID: assetID)
                try host.session.apply(.replaceInk(selection.pageID, layerID, dataAssetID: assetID))
            }
        }
        dragTransform = .identity
        refreshOverlay()
    }

    /// "Move" for a translation, "Rotate" for a pure rotation, otherwise "Resize".
    static func operationName(for t: PageTransform) -> String {
        let eps = 1e-9
        if abs(t.a - 1) <= eps, abs(t.d - 1) <= eps, abs(t.b) <= eps, abs(t.c) <= eps { return "Move" }
        if abs(t.a - t.d) <= eps, abs(t.b + t.c) <= eps, abs(t.a * t.a + t.b * t.b - 1) <= eps { return "Rotate" }
        return "Resize"
    }

    /// Scale about the handle's opposite side; corners keep the aspect ratio.
    static func resizeTransform(handle: SelectionHandle, initial: CGRect, point: CGPoint) -> PageTransform {
        let minSize: CGFloat = 4
        var anchor = CGPoint(x: initial.midX, y: initial.midY)
        var sx: CGFloat = 1, sy: CGFloat = 1
        switch handle {
        case .right, .topRight, .bottomRight: anchor.x = initial.minX
        case .left, .topLeft, .bottomLeft: anchor.x = initial.maxX
        default: break
        }
        switch handle {
        case .bottom, .bottomLeft, .bottomRight: anchor.y = initial.minY
        case .top, .topLeft, .topRight: anchor.y = initial.maxY
        default: break
        }
        let width = max(initial.width, 0.001), height = max(initial.height, 0.001)
        switch handle {
        case .right, .topRight, .bottomRight: sx = max(minSize, point.x - anchor.x) / width
        case .left, .topLeft, .bottomLeft: sx = max(minSize, anchor.x - point.x) / width
        default: break
        }
        switch handle {
        case .bottom, .bottomLeft, .bottomRight: sy = max(minSize, point.y - anchor.y) / height
        case .top, .topLeft, .topRight: sy = max(minSize, anchor.y - point.y) / height
        default: break
        }
        if handle.isCorner {
            let s = max(sx, sy)
            sx = s; sy = s
        }
        return PageTransform.translation(x: -Double(anchor.x), y: -Double(anchor.y))
            .concatenating(.scale(x: Double(sx), y: Double(sy)))
            .concatenating(.translation(x: Double(anchor.x), y: Double(anchor.y)))
    }

    // MARK: Object creation (shape, tape, text)

    private func creationShape(for tool: EditorTool, from start: CGPoint = .zero, to end: CGPoint = .zero) -> ShapeContent? {
        guard case .shape(let kind) = tool, let host else { return nil }
        var shape = host.toolState.newShapeContent(kind)
        if kind == .line || kind == .arrow {
            shape.start = PagePoint(x: end.x >= start.x ? 0 : 1, y: end.y >= start.y ? 0 : 1)
            shape.end = PagePoint(x: end.x >= start.x ? 1 : 0, y: end.y >= start.y ? 1 : 0)
        }
        return shape
    }

    private func createObject(tool: EditorTool, from start: CGPoint, to end: CGPoint, canvas: PageCanvasView) {
        guard let host else { return }
        var frame = rect(from: start, to: end)
        switch tool {
        case .shape(let kind):
            if frame.width < 4 && frame.height < 4 { return }
            if kind == .line || kind == .arrow {
                frame.size.width = max(frame.width, 1); frame.size.height = max(frame.height, 1)
            } else {
                frame.size.width = max(frame.width, 8); frame.size.height = max(frame.height, 8)
            }
            guard let shape = creationShape(for: tool, from: start, to: end) else { return }
            let object = CanvasObject(frame: PageRect(frame), content: .shape(shape), createdAt: now())
            host.performDocumentOperation("Add \(ShapeKindNames.name(kind))") {
                try host.session.apply(.addObject(canvas.pageID, object, at: nil))
            }
            selectObject(object.id, on: canvas.pageID)
        case .tape:
            if frame.width < 6 || frame.height < 6 {
                frame = CGRect(x: start.x - 60, y: start.y - 14, width: 120, height: 28)
            }
            let object = CanvasObject(frame: PageRect(frame), content: .tape(host.toolState.newTapeContent()), createdAt: now())
            host.performDocumentOperation("Add Tape") {
                try host.session.apply(.addObject(canvas.pageID, object, at: nil))
            }
        case .text:
            createTextBox(at: start, size: frame.width > 20 ? frame.size : nil, canvas: canvas)
        default:
            break
        }
    }

    private func createTextBox(at point: CGPoint, size: CGSize?, canvas: PageCanvasView) {
        guard let host, let page = host.session.editor.page(canvas.pageID) else { return }
        let content = host.toolState.newTextContent()
        // Keep the arithmetic in `Double` (page points); `size` is a CGSize? from the drag.
        let width: Double = size.map { Double($0.width) } ?? min(220, max(60, page.size.width - Double(point.x) - 8))
        let height: Double = max(size.map { Double($0.height) } ?? 0, TextObjectView.fittingHeight(for: content, width: width))
        let object = CanvasObject(frame: PageRect(x: Double(point.x), y: Double(point.y), width: width, height: height),
                                  content: .text(content), createdAt: now())
        host.performDocumentOperation("Add Text") {
            try host.session.apply(.addObject(canvas.pageID, object, at: nil))
        }
        selectObject(object.id, on: canvas.pageID)
        canvas.objectLayer.beginEditingText(object.id)
    }

    /// Text editing finished on a canvas: store the text (and grown height); delete empty new boxes.
    func textEditingEnded(objectID: ObjectID, text: String, fittingHeight: Double, canvas: PageCanvasView) {
        guard let host, let page = host.session.editor.page(canvas.pageID), var object = page.object(objectID),
              case .text(var content) = object.content else { return }
        if text.isEmpty {
            host.performDocumentOperation("Delete Text") {
                try host.session.apply(.removeObjects(canvas.pageID, [objectID]))
            }
            if selection?.objectIDs.contains(objectID) == true { clearSelection() }
            return
        }
        guard content.text != text || fittingHeight > object.frame.height else { return }
        content.text = text
        object.content = .text(content)
        object.frame.size.height = max(object.frame.height, fittingHeight)
        host.performDocumentOperation("Edit Text") {
            try host.session.apply(.updateObject(canvas.pageID, object))
        }
        refreshOverlay()
    }

    // MARK: Menu

    func presentMenu(on canvas: PageCanvasView, at point: CGPoint) {
        guard let interaction = menuInteractions[ObjectIdentifier(canvas)] else { return }
        let configuration = UIEditMenuConfiguration(identifier: canvas.pageID.description as NSString, sourcePoint: point)
        configuration.preferredArrowDirection = .down
        interaction.presentEditMenu(with: configuration)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let overlay = interaction.view as? SelectionOverlayView, let canvas = canvas(of: overlay) else { return nil }
        return menu(for: canvas, at: configuration.sourcePoint)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        if let overlay = interaction.view as? SelectionOverlayView, let bounds = overlay.selectionBounds,
           selection?.pageID == (overlay.superview as? PageCanvasView)?.pageID {
            return bounds
        }
        return CGRect(origin: configuration.sourcePoint, size: .zero).insetBy(dx: -2, dy: -2)
    }

    /// The contextual menu for the selection (or the page when nothing is selected).
    func menu(for canvas: PageCanvasView, at point: CGPoint) -> UIMenu {
        let actions = selection?.pageID == canvas.pageID ? availableActions() : [.paste, .addToReview]
        var items: [UIMenuElement] = []
        func add(_ action: SelectionAction, _ title: String, _ symbol: String, attributes: UIMenuElement.Attributes = [], handler: @escaping () -> Void) {
            guard actions.contains(action) else { return }
            items.append(UIAction(title: title, image: UIImage(systemName: symbol), attributes: attributes) { _ in handler() })
        }
        add(.editText, "Edit Text", "pencil") { [weak self] in self?.editText(on: canvas) }
        add(.cropImage, "Crop", "crop") { [weak self] in self?.cropImage(on: canvas) }
        add(.copy, "Copy", "doc.on.doc") { [weak self] in self?.copySelection(on: canvas) }
        add(.cut, "Cut", "scissors") { [weak self] in self?.cutSelection(on: canvas) }
        if actions.contains(.paste) && EditorPasteboard.hasContent() {
            items.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.paste(on: canvas, at: PagePoint(point))
            })
        }
        add(.duplicate, "Duplicate", "plus.square.on.square") { [weak self] in self?.duplicateSelection(on: canvas) }
        if actions.contains(.recolor) {
            var colorItems: [UIMenuElement] = EditorToolState.colorPresets.map { color in
                UIAction(title: color.hexString, image: Self.swatch(color)) { [weak self] _ in self?.recolorSelection(to: color, on: canvas) }
            }
            colorItems.append(UIAction(title: "Custom Color…", image: UIImage(systemName: "paintpalette")) { [weak self] _ in
                guard let self, let host = self.host else { return }
                let anchor = canvas.overlay.selectionBounds ?? CGRect(origin: point, size: .zero)
                host.presentColorPicker(anchor: canvas.overlay, anchorRect: anchor, current: .black) { [weak self] color in
                    self?.recolorSelection(to: color, on: canvas)
                }
            })
            items.append(UIMenu(title: "Recolor", image: UIImage(systemName: "paintbrush"), children: colorItems))
        }
        add(.revealTape, "Reveal", "eye") { [weak self] in self?.setTapeRevealed(true, on: canvas) }
        add(.hideTape, "Hide", "eye.slash") { [weak self] in self?.setTapeRevealed(false, on: canvas) }
        add(.lock, "Lock", "lock") { [weak self] in self?.setLocked(true, on: canvas) }
        add(.unlock, "Unlock", "lock.open") { [weak self] in self?.setLocked(false, on: canvas) }
        add(.bringToFront, "Bring to Front", "square.3.layers.3d.top.filled") { [weak self] in self?.reorder(toFront: true, on: canvas) }
        add(.sendToBack, "Send to Back", "square.3.layers.3d.bottom.filled") { [weak self] in self?.reorder(toFront: false, on: canvas) }
        add(.addToReview, "Add to Review", "checklist") { [weak self] in self?.addToReview(on: canvas, at: PagePoint(point)) }
        add(.delete, "Delete", "trash", attributes: .destructive) { [weak self] in self?.deleteSelection(on: canvas) }
        return UIMenu(children: items)
    }

    private static func swatch(_ color: RGBAColor) -> UIImage {
        let size = CGSize(width: 18, height: 18)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(color).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    // MARK: Actions

    private func selectedObjects(in page: Page) -> [CanvasObject] {
        guard let selection else { return [] }
        return page.objects.filter { selection.objectIDs.contains($0.id) }
    }

    private func strokeIndicesOfSelection() -> [Int] {
        selection?.strokeIndices.values.flatMap { $0 } ?? []
    }

    func editText(on canvas: PageCanvasView) {
        guard let id = selection?.objectIDs.first else { return }
        canvas.objectLayer.beginEditingText(id)
    }

    func cropImage(on canvas: PageCanvasView) {
        guard let host, let page = currentPage, let id = selection?.objectIDs.first, let object = page.object(id) else { return }
        host.presentImageCrop(pageID: page.id, object: object)
    }

    func copySelection(on canvas: PageCanvasView) {
        guard let host, selection != nil, let page = currentPage else { return }
        let objects = selectedObjects(in: page)
        let indices = strokeIndicesOfSelection()
        let ink = indices.isEmpty ? nil : PencilKitDrawing(drawing: canvas.drawing).extractingStrokes(indices).drawing.dataRepresentation()
        let imageIDs = objects.compactMap(\.content.assetID)
        let session = host.session
        let pageSize = page.size
        Task {
            var assets: [String: Data] = [:]
            for id in imageIDs {
                if let data = (try? await session.assetData(id)) ?? nil { assets[id.description] = data }
            }
            let payload = EditorPasteboardPayload(objects: objects, inkData: ink, inkEngine: InkEngineIdentifier.pencilKit.rawValue,
                                                  sourcePageSize: pageSize, imageAssets: assets)
            EditorPasteboard.write(payload)
        }
    }

    func cutSelection(on canvas: PageCanvasView) {
        copySelection(on: canvas)
        deleteSelection(on: canvas)
    }

    func deleteSelection(on canvas: PageCanvasView) {
        guard let host, let selection, let page = currentPage else { return }
        let objectIDs = selectedObjects(in: page).filter { !$0.isLocked }.map(\.id)
        let indices = strokeIndicesOfSelection()
        host.performDocumentOperation("Delete") {
            if !objectIDs.isEmpty { try host.session.apply(.removeObjects(selection.pageID, objectIDs)) }
            if !indices.isEmpty, let layerID = canvas.inkLayerID {
                let remaining = PencilKitDrawing(drawing: canvas.drawing).removingStrokes(indices)
                let assetID = host.registerInkAsset(remaining.drawing)
                canvas.setDrawing(remaining.drawing, assetID: assetID)
                try host.session.apply(.replaceInk(selection.pageID, layerID, dataAssetID: assetID))
            }
        }
        clearSelection()
    }

    func duplicateSelection(on canvas: PageCanvasView) {
        guard let host, let selection, let page = currentPage else { return }
        let offset = PagePoint(x: 20, y: 20)
        let objects = selectedObjects(in: page)
        let indices = strokeIndicesOfSelection()
        let payload = ClipboardPayload(objects: objects, sourcePageSize: page.size)
        var newIDs: Set<ObjectID> = []
        var newStrokes: [Int] = []
        host.performDocumentOperation("Duplicate") {
            for command in payload.pasteCommands(into: selection.pageID, offset: offset, now: now()) {
                if case .addObjects(_, let added) = command { newIDs.formUnion(added.map(\.id)) }
                try host.session.apply(command)
            }
            if !indices.isEmpty, let layerID = canvas.inkLayerID {
                let current = PencilKitDrawing(drawing: canvas.drawing)
                let copies = current.extractingStrokes(indices).transformingStrokes(Array(0..<indices.count), by: .translation(x: offset.x, y: offset.y))
                let combined = current.appending(copies)
                newStrokes = Array(current.strokeCount..<combined.strokeCount)
                let assetID = host.registerInkAsset(combined.drawing)
                canvas.setDrawing(combined.drawing, assetID: assetID)
                try host.session.apply(.replaceInk(selection.pageID, layerID, dataAssetID: assetID))
            }
        }
        var strokeMap: [InkLayerID: [Int]] = [:]
        if let layerID = canvas.inkLayerID, !newStrokes.isEmpty { strokeMap[layerID] = newStrokes }
        select(Selection(pageID: selection.pageID, objectIDs: newIDs, strokeIndices: strokeMap))
    }

    func paste(on canvas: PageCanvasView, at point: PagePoint?) {
        guard let host, let payload = EditorPasteboard.read(), !payload.isEmpty,
              let page = host.session.editor.page(canvas.pageID) else {
            pasteForeignContent(on: canvas, at: point)
            return
        }
        let pageID = canvas.pageID
        // Offset: keep the copied position (+20,+20) but stay on the page.
        var offset = PagePoint(x: 20, y: 20)
        if let bounds = PageRect.bounding(payload.objects.flatMap { $0.bounds.corners }) {
            offset.x = min(offset.x, page.size.width - bounds.maxX - 4)
            offset.y = min(offset.y, page.size.height - bounds.maxY - 4)
        }
        var objects = payload.objects
        var assetMap: [AssetID: AssetID] = [:]
        for (key, data) in payload.imageAssets {
            guard let original = AssetID(uuidString: key) else { continue }
            if host.session.editor.snapshot.assets[original] != nil { assetMap[original] = original; continue }
            guard let type = EditorAssets.imageMediaType(of: data) else { continue }
            assetMap[original] = host.registerImageAsset(data: data, mediaType: type)
        }
        objects = objects.compactMap { object in
            var o = object
            if case .image(var content) = o.content {
                guard let mapped = assetMap[content.assetID] else { return nil }
                content.assetID = mapped
                o.content = .image(content)
            }
            return o
        }
        let clipboard = ClipboardPayload(objects: objects, sourcePageSize: payload.sourcePageSize)
        var newIDs: Set<ObjectID> = []
        var newStrokes: [Int] = []
        host.performDocumentOperation("Paste") {
            for command in clipboard.pasteCommands(into: pageID, offset: offset, now: now()) {
                if case .addObjects(_, let added) = command { newIDs.formUnion(added.map(\.id)) }
                try host.session.apply(command)
            }
            if let inkData = payload.inkData, payload.inkEngine == InkEngineIdentifier.pencilKit.rawValue,
               let pasted = try? PencilKitInkEngine().decode(inkData), !pasted.isEmpty, let layerID = canvas.inkLayerID {
                let current = PencilKitDrawing(drawing: canvas.drawing)
                let moved = pasted.transformingStrokes(Array(0..<pasted.strokeCount), by: .translation(x: offset.x, y: offset.y))
                let combined = current.appending(moved)
                newStrokes = Array(current.strokeCount..<combined.strokeCount)
                let assetID = host.registerInkAsset(combined.drawing)
                canvas.setDrawing(combined.drawing, assetID: assetID)
                try host.session.apply(.replaceInk(pageID, layerID, dataAssetID: assetID))
            }
        }
        var strokeMap: [InkLayerID: [Int]] = [:]
        if let layerID = canvas.inkLayerID, !newStrokes.isEmpty { strokeMap[layerID] = newStrokes }
        select(Selection(pageID: pageID, objectIDs: newIDs, strokeIndices: strokeMap))
    }

    /// Images or plain text from other apps become image/text objects.
    private func pasteForeignContent(on canvas: PageCanvasView, at point: PagePoint?) {
        guard let host, let page = host.session.editor.page(canvas.pageID) else { return }
        let pasteboard = UIPasteboard.general
        let origin = point ?? PagePoint(x: page.size.width * 0.2, y: page.size.height * 0.2)
        if let image = pasteboard.image, let stored = EditorAssets.storableImage(from: pasteboard.data(forPasteboardType: UTTypeIdentifiers.png) ?? pasteboard.data(forPasteboardType: UTTypeIdentifiers.jpeg), image: image) {
            let assetID = host.registerImageAsset(data: stored.0, mediaType: stored.1)
            let maxWidth = page.size.width * 0.6
            let scale = min(1, maxWidth / max(Double(stored.2.width), 1))
            let frame = PageRect(x: origin.x, y: origin.y, width: Double(stored.2.width) * scale, height: Double(stored.2.height) * scale)
            let object = CanvasObject(frame: frame, content: .image(ImageContent(assetID: assetID)), createdAt: now())
            host.performDocumentOperation("Paste Image") { try host.session.apply(.addObject(canvas.pageID, object, at: nil)) }
            selectObject(object.id, on: canvas.pageID)
        } else if let text = pasteboard.string, !text.isEmpty {
            let content = host.toolState.newTextContent(text)
            let width = min(300, page.size.width - origin.x - 8)
            let height = TextObjectView.fittingHeight(for: content, width: width)
            let object = CanvasObject(frame: PageRect(x: origin.x, y: origin.y, width: width, height: height), content: .text(content), createdAt: now())
            host.performDocumentOperation("Paste Text") { try host.session.apply(.addObject(canvas.pageID, object, at: nil)) }
            selectObject(object.id, on: canvas.pageID)
        }
    }

    func recolorSelection(to color: RGBAColor, on canvas: PageCanvasView) {
        guard let host, let selection, let page = currentPage else { return }
        let objects = selectedObjects(in: page)
        let indices = strokeIndicesOfSelection()
        host.performDocumentOperation("Recolor") {
            for var object in objects where !object.isLocked {
                switch object.content {
                case .text(var t): t.color = color; object.content = .text(t)
                case .shape(var s): s.strokeColor = color; object.content = .shape(s)
                default: continue
                }
                try host.session.apply(.updateObject(selection.pageID, object))
            }
            if !indices.isEmpty, let layerID = canvas.inkLayerID {
                // Rebuilds strokes with the same path, transform and erase mask (A10).
                let recolored = PencilKitDrawing(drawing: canvas.drawing).recoloringStrokes(indices, to: color)
                let assetID = host.registerInkAsset(recolored.drawing)
                canvas.setDrawing(recolored.drawing, assetID: assetID)
                try host.session.apply(.replaceInk(selection.pageID, layerID, dataAssetID: assetID))
            }
        }
        host.toolState.noteColor(color)
    }

    func setTapeRevealed(_ revealed: Bool, on canvas: PageCanvasView) {
        guard let host, let selection, let page = currentPage else { return }
        let tapes = selectedObjects(in: page).filter { $0.kind == .tape }
        host.performDocumentOperation(revealed ? "Reveal" : "Hide") {
            for tape in tapes { try host.session.apply(.setTapeRevealed(selection.pageID, tape.id, revealed)) }
        }
    }

    func setLocked(_ locked: Bool, on canvas: PageCanvasView) {
        guard let host, let selection else { return }
        let ids = Array(selection.objectIDs)
        host.performDocumentOperation(locked ? "Lock" : "Unlock") {
            try host.session.apply(.setObjectsLocked(selection.pageID, ids, locked))
        }
        if locked { clearSelection() } else { refreshOverlay() }
    }

    func reorder(toFront: Bool, on canvas: PageCanvasView) {
        guard let host, let selection else { return }
        let ids = Array(selection.objectIDs)
        host.performDocumentOperation(toFront ? "Bring to Front" : "Send to Back") {
            try host.session.apply(toFront ? .bringToFront(selection.pageID, ids) : .sendToBack(selection.pageID, ids))
        }
    }

    func addToReview(on canvas: PageCanvasView, at point: PagePoint) {
        guard let host else { return }
        let region = selectionBounds()
        let item = ReviewItem(pageID: canvas.pageID, region: region, createdAt: now())
        host.performDocumentOperation("Add to Review") {
            try host.session.apply(.addReviewItem(item))
        }
    }

    // MARK: Keyboard helpers

    func selectAll(on canvas: PageCanvasView) {
        guard let host, let page = host.session.editor.page(canvas.pageID) else { return }
        let filter = host.toolState.selectionFilter
        let ids = page.objects.filter { !$0.isLocked && filter.allows($0.kind) }.map(\.id)
        var strokeMap: [InkLayerID: [Int]] = [:]
        if filter.contains(.ink), let layerID = canvas.inkLayerID, canvas.drawing.strokes.count > 0 {
            strokeMap[layerID] = Array(0..<canvas.drawing.strokes.count)
        }
        select(Selection(pageID: canvas.pageID, objectIDs: Set(ids), strokeIndices: strokeMap))
    }

    func nudge(dx: Double, dy: Double) {
        guard let canvas = currentCanvas, availableActions().contains(.move) else { return }
        beginTransformPreview(canvas: canvas)
        dragTransform = .translation(x: dx, y: dy)
        commitTransform(dragTransform, canvas: canvas)
    }
}

private enum UTTypeIdentifiers {
    static let png = "public.png"
    static let jpeg = "public.jpeg"
}
