import Foundation
import UIKit
import PencilKit
import PDFKit
import DocumentCore
import PageGeometry
import Editing

@MainActor
protocol PageCanvasViewHost: AnyObject {
    /// A stroke or erase gesture finished, or PencilKit undid/redid one (check the undo manager state).
    func canvasDrawingDidChange(_ canvas: PageCanvasView)
    func canvasDidBeginUsingTool(_ canvas: PageCanvasView)
    /// One pen-down-to-pen-up gesture ended. This, not a timer, is where an
    /// undo step ends: a pause in the middle of a stroke never splits it, and
    /// two quick strokes are still two steps.
    func canvasDidEndUsingTool(_ canvas: PageCanvasView)
    /// The student asked to try loading unreadable ink again.
    func canvasWantsInkReload(_ canvas: PageCanvasView)
    func canvas(_ canvas: PageCanvasView, tapeWantsRevealed id: ObjectID, revealed: Bool)
    func canvas(_ canvas: PageCanvasView, didTapObject id: ObjectID, tapCount: Int)
    func canvas(_ canvas: PageCanvasView, textEditingBegan id: ObjectID)
    func canvas(_ canvas: PageCanvasView, textEditingEnded id: ObjectID, text: String, fittingHeight: Double)
    /// A tap in reading mode (page space): follow a PDF link if one is there.
    func canvas(_ canvas: PageCanvasView, readingModeTapAt point: PagePoint)
}

/// One live page (docs/ARCHITECTURE.md §4), back to front: tiled background,
/// image objects, the PencilKit canvas, text/shape/tape objects, selection
/// overlay. The view's frame is the page's frame in unzoomed content space,
/// so every subview works in page points.
final class PageCanvasView: UIView, PKCanvasViewDelegate, ObjectLayerViewDelegate {
    let pageID: PageID
    private(set) var page: Page
    private(set) var mapping: PageMapping
    weak var host: PageCanvasViewHost?
    private weak var loader: PageContentLoader?

    let background = PageBackgroundLayerView(frame: .zero)
    let imageLayer = ImageObjectLayerView(frame: .zero)
    let canvasHost = InkCanvasHostView(frame: .zero)
    let canvasView = PKCanvasView(frame: .zero)
    let objectLayer = ObjectLayerView(frame: .zero)
    let overlay = SelectionOverlayView(frame: .zero)
    private let failureView = InkUnavailableView(frame: .zero)
    private let shapePreview = ShapePreviewLayerView(frame: .zero)
    private let readingTap = UITapGestureRecognizer()
    /// Watches the same touches PencilKit is drawing with, without taking them.
    let strokeSampler = StrokeSamplingGestureRecognizer()
    /// Stroke count when the current gesture began, so the stroke it produced
    /// can be identified without guessing at PencilKit's internals.
    var strokeCountAtGestureStart = 0

    /// The ink asset the canvas drawing currently represents (nil = empty / never drawn).
    private(set) var loadedInkAssetID: AssetID?
    private(set) var hasLoadedInk = false
    /// Set when the page's ink could not be produced. While this is set the
    /// canvas refuses input, so the next stroke cannot overwrite a reference
    /// whose bytes we never managed to read.
    private(set) var inkFailure: InkLoadOutcome?

    // Ink bookkeeping. Two counters, because they answer different questions.
    //
    //  * `drawingGeneration` counts every change to the live drawing. It is what
    //    "has this page got edits the document has not seen" is derived from,
    //    so a late, stale serialization result cannot mark newer ink saved.
    //  * `drawingEpoch` counts only the times the drawing was *re-established*
    //    from outside — loaded, undone, cleared, edited by the lasso, or
    //    committed synchronously. Any serialization started before the current
    //    epoch describes a drawing that no longer exists and is discarded.
    private(set) var drawingGeneration = 0
    private(set) var committedDrawingGeneration = 0
    private(set) var drawingEpoch = 0
    /// True while strokes are lifted into a drag preview, when the canvas's
    /// drawing is deliberately incomplete and must not be committed.
    private(set) var isPreviewingInkDrag = false
    /// True between pen-down and pen-up. The save timer stands down while this
    /// is set: a pause in the middle of a long stroke must not turn into an
    /// undo boundary halfway through it.
    private(set) var isUsingTool = false

    /// Edits the document has not been told about yet.
    var hasUncommittedDrawing: Bool {
        inkFailure == nil && !isPreviewingInkDrag && drawingGeneration > committedDrawingGeneration
    }

    private var inkLoadTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    private var backgroundKey: String = ""
    /// Floating preview of ink strokes being dragged (strokes are temporarily removed from the canvas).
    private var inkPreview: UIImageView?
    private var inkPreviewOrigin: CGPoint = .zero
    var isReadingMode = false { didSet { applyInteractionPolicy() } }
    var activeTool: EditorTool = .ink(.pen) { didSet { applyInteractionPolicy() } }
    var drawingEnabled = true { didSet { applyInteractionPolicy() } }
    /// True while the host itself is setting the drawing so delegate callbacks are ignored.
    private var isSettingDrawingProgrammatically = false

    var inkLayerID: InkLayerID? { page.inkLayers.first?.id }
    var currentInkAssetID: AssetID? { page.inkLayers.first?.dataAssetID }

    init(page: Page, host: PageCanvasViewHost?, loader: PageContentLoader?) {
        self.pageID = page.id
        self.page = page
        self.mapping = Self.mapping(for: page)
        self.host = host
        self.loader = loader
        super.init(frame: CGRect(origin: .zero, size: CGSize(page.size)))
        isOpaque = true
        backgroundColor = .white
        clipsToBounds = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)

        for sub in [background, imageLayer, canvasHost, shapePreview, objectLayer, overlay, failureView] as [UIView] {
            sub.frame = bounds
            sub.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(sub)
        }
        canvasView.frame = canvasHost.bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasHost.addSubview(canvasView)
        canvasHost.addGestureRecognizer(strokeSampler)
        failureView.isHidden = true
        failureView.onRetry = { [weak self] in
            guard let self else { return }
            self.host?.canvasWantsInkReload(self)
        }
        imageLayer.loader = loader
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.isScrollEnabled = false
        canvasView.showsVerticalScrollIndicator = false
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.delegate = self
        canvasView.drawingPolicy = .pencilOnly
        canvasView.accessibilityLabel = "Handwriting canvas"
        canvasView.isUserInteractionEnabled = false   // until the ink asset has loaded
        objectLayer.delegate = self
        readingTap.addTarget(self, action: #selector(handleReadingTap(_:)))
        readingTap.isEnabled = false
        addGestureRecognizer(readingTap)
        accessibilityLabel = "Page"
        configure(with: page)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func mapping(for page: Page) -> PageMapping {
        switch page.background {
        case .pdf(let source): return PageMapping(source: source)
        case .template, .image: return PageMapping(templateSize: page.size)
        }
    }

    // MARK: Model updates

    /// Full configuration (first load or background change).
    func configure(with page: Page) {
        self.page = page
        mapping = Self.mapping(for: page)
        let size = CGSize(page.size)
        if bounds.size != size { bounds = CGRect(origin: .zero, size: size) }
        reloadBackground()
        imageLayer.update(objects: page.objects)
        objectLayer.update(objects: page.objects)
        reloadInkIfNeeded()
        applyInteractionPolicy()
    }

    /// Applies a changed page value: objects are diffed, the background and
    /// ink reload only when their identity changed.
    func apply(page newPage: Page) {
        let oldPage = page
        page = newPage
        if oldPage.background != newPage.background || oldPage.size != newPage.size {
            mapping = Self.mapping(for: newPage)
            let size = CGSize(newPage.size)
            if bounds.size != size { bounds = CGRect(origin: .zero, size: size) }
            reloadBackground()
        }
        if oldPage.objects != newPage.objects {
            imageLayer.update(objects: newPage.objects)
            objectLayer.update(objects: newPage.objects)
        }
        reloadInkIfNeeded()
    }

    private func reloadBackground() {
        guard let loader else { background.content = .empty(paperColor: .white); return }
        let key: String
        switch page.background {
        case .template(let t): key = "template-\(t.hashValue)-\(page.size.width)x\(page.size.height)"
        case .pdf(let s): key = "pdf-\(s.assetID)-\(s.pageIndex)-\(s.rotation.rawValue)"
        case .image(let id): key = "image-\(id)"
        }
        guard key != backgroundKey else { return }
        backgroundKey = key
        backgroundTask?.cancel()
        let page = self.page
        backgroundTask = Task { [weak self] in
            let content = await PageContentResolver.background(for: page, loader: loader)
            guard !Task.isCancelled, let self, self.backgroundKey == key else { return }
            self.background.content = content
        }
    }

    private func reloadInkIfNeeded() {
        let target = currentInkAssetID
        if hasLoadedInk, inkFailure == nil, target == loadedInkAssetID { return }
        inkLoadTask?.cancel()
        guard let target else {
            applyLoaded(.empty, assetID: nil)
            return
        }
        if let loader, let cached = loader.decoded.drawing(for: target) {
            applyLoaded(.loaded(cached), assetID: target)
            return
        }
        guard let loader else {
            // No loader is a wiring failure, not an empty page; refuse to draw
            // rather than let the next stroke stand in for the page's ink.
            applyLoaded(.missing(target), assetID: target)
            return
        }
        applyLoading()
        inkLoadTask = Task { [weak self] in
            let outcome = await loader.loadDrawing(for: target)
            guard !Task.isCancelled, let self, self.currentInkAssetID == target else { return }
            self.applyLoaded(outcome, assetID: target)
        }
    }

    /// Retries a failed ink load from the top.
    func reloadInk() {
        inkFailure = nil
        hasLoadedInk = false
        loadedInkAssetID = nil
        reloadInkIfNeeded()
    }

    private func applyLoading() {
        hasLoadedInk = false
        inkFailure = nil
        failureView.isHidden = true
        applyInteractionPolicy()
    }

    private func applyLoaded(_ outcome: InkLoadOutcome, assetID: AssetID?) {
        switch outcome {
        case .empty, .loaded:
            inkFailure = nil
            failureView.isHidden = true
            setDrawing(outcome.drawing ?? PKDrawing(), assetID: assetID)
        case .missing, .unreadable:
            // Never stand in an empty drawing for content we could not read: the
            // canvas stays out of the way, the page keeps its asset reference,
            // and the student is offered a retry.
            inkFailure = outcome
            hasLoadedInk = false
            loadedInkAssetID = nil
            failureView.message = outcome.failureDescription ?? "This page's handwriting is unavailable."
            failureView.isHidden = false
            bringSubviewToFront(failureView)
            applyInteractionPolicy()
        }
    }

    /// Sets the canvas drawing without going through PencilKit's undo. Every
    /// caller is re-establishing the drawing from the document (a load, an undo,
    /// a lasso edit, a clear), so this both counts as a change and closes the
    /// epoch: anything still being serialized from before is now stale.
    func setDrawing(_ drawing: PKDrawing, assetID: AssetID?) {
        isSettingDrawingProgrammatically = true
        canvasView.drawing = drawing
        isSettingDrawingProgrammatically = false
        loadedInkAssetID = assetID
        hasLoadedInk = true
        inkFailure = nil
        failureView.isHidden = true
        drawingGeneration += 1
        drawingEpoch += 1
        committedDrawingGeneration = drawingGeneration
        applyInteractionPolicy()
    }

    /// Records that the document now holds `generation` of this page's drawing.
    /// A result from an older generation never moves the mark forward.
    func noteInkCommitted(assetID: AssetID?, generation: Int) {
        loadedInkAssetID = assetID
        hasLoadedInk = true
        if generation > committedDrawingGeneration { committedDrawingGeneration = generation }
    }

    /// Invalidates any serialization already in flight for this canvas.
    func closeDrawingEpoch() { drawingEpoch += 1 }

    var drawing: PKDrawing { canvasView.drawing }

    /// Every visible stroke as a page-space polyline, for geometric hit testing
    /// that must not fall back to bounding rectangles.
    func inkTargets() -> [ScribbleEraseTarget] {
        let strokes = canvasView.drawing.strokes
        return strokes.indices.map { index in
            let stroke = strokes[index]
            let width = stroke.path.first?.size.width ?? 2
            return ScribbleEraseTarget(index: index,
                                       polyline: PencilKitDrawing.visibleLocations(of: stroke),
                                       halfWidth: Double(width) / 2)
        }
    }

    // MARK: Tools and interaction

    func setPencilKitTool(_ tool: PKTool?) {
        if let tool { canvasView.tool = tool }
    }

    func setDrawingPolicy(_ policy: PKCanvasViewDrawingPolicy) {
        canvasView.drawingPolicy = policy
        // Record only the touches that can actually draw, so a finger resting on
        // the page never contributes samples to a pencil gesture.
        switch policy {
        case .pencilOnly: strokeSampler.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        default: strokeSampler.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                                    NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        }
    }

    private func applyInteractionPolicy() {
        let inkActive = activeTool.isInkTool && !isReadingMode && drawingEnabled && hasLoadedInk && inkFailure == nil
        canvasHost.isUserInteractionEnabled = inkActive
        canvasView.isUserInteractionEnabled = inkActive
        canvasView.drawingGestureRecognizer.isEnabled = inkActive
        objectLayer.isReadingMode = isReadingMode
        objectLayer.objectsInteractive = !isReadingMode && (activeTool == .lasso || activeTool == .text)
        overlay.isReadingMode = isReadingMode
        overlay.acceptsDrags = !isReadingMode && activeTool.usesOverlayDrag
        readingTap.isEnabled = isReadingMode
        if !(activeTool == .lasso || activeTool == .text) { objectLayer.endTextEditing() }
    }

    /// Called after zooming so vector content renders sharply at the on-screen scale.
    func setDisplayZoom(_ zoom: CGFloat, screenScale: CGFloat) {
        overlay.displayZoom = zoom
        objectLayer.setShapeHitTolerance(8 / max(zoom, 0.01))
        // Bound the canvas's backing store: a letter page at 4x Retina is ~31 MB.
        let scale = min(screenScale * max(zoom, 1), 4)
        if canvasView.contentScaleFactor != scale {
            canvasView.contentScaleFactor = scale
            for sub in canvasView.subviews { sub.contentScaleFactor = scale }
        }
    }

    // MARK: Ink drag preview

    /// Removes the strokes from the canvas (no undo registration) and shows
    /// them as a floating image that follows a transform preview.
    func beginInkPreview(strokeIndices: [Int], screenScale: CGFloat, zoom: CGFloat) -> PKDrawing {
        endInkPreview()
        isPreviewingInkDrag = true
        drawingEpoch += 1
        let all = PencilKitDrawing(drawing: canvasView.drawing)
        let extracted = all.extractingStrokes(strokeIndices)
        guard !extracted.isEmpty else { return extracted.drawing }
        let remaining = all.removingStrokes(strokeIndices)
        isSettingDrawingProgrammatically = true
        canvasView.drawing = remaining.drawing
        isSettingDrawingProgrammatically = false
        let bounds = extracted.drawing.bounds.insetBy(dx: -4, dy: -4)
        let image = extracted.drawing.image(from: bounds, scale: min(screenScale * max(zoom, 1), 4))
        let view = UIImageView(image: image)
        view.frame = bounds
        view.layer.anchorPoint = .zero
        view.layer.position = bounds.origin
        inkPreviewOrigin = bounds.origin
        insertSubview(view, aboveSubview: canvasHost)
        inkPreview = view
        return extracted.drawing
    }

    func updateInkPreview(transform: PageTransform) {
        inkPreview?.layer.setAffineTransform(transform.layerTransform(forLayerOrigin: PagePoint(inkPreviewOrigin)))
    }

    /// Removes the floating preview. The caller sets the final drawing afterwards.
    func endInkPreview() {
        inkPreview?.removeFromSuperview()
        inkPreview = nil
        isPreviewingInkDrag = false
    }

    /// Restores a drawing after a cancelled drag (no undo registration).
    func restoreDrawingAfterCancelledPreview(_ drawing: PKDrawing) {
        endInkPreview()
        setDrawing(drawing, assetID: loadedInkAssetID)
    }

    func prepareForReuse() {
        inkLoadTask?.cancel()
        backgroundTask?.cancel()
        imageLayer.cancelLoads()
        objectLayer.endTextEditing()
        endInkPreview()
        hideShapePreview()
        strokeSampler.clear()
        isUsingTool = false
    }

    // MARK: Shape preview

    func showShapePreview(_ shape: RecognizedShape, color: UIColor, width: CGFloat) {
        shapePreview.show(shape, color: color, width: width,
                          reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    func hideShapePreview() { shapePreview.hide() }

    var isShowingShapePreview: Bool { !shapePreview.isHidden }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isSettingDrawingProgrammatically else { return }
        drawingGeneration += 1
        host?.canvasDrawingDidChange(self)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        isUsingTool = true
        host?.canvasDidBeginUsingTool(self)
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        isUsingTool = false
        host?.canvasDidEndUsingTool(self)
    }

    // MARK: ObjectLayerViewDelegate

    func objectLayer(_ layer: ObjectLayerView, didTap objectID: ObjectID, tapCount: Int) {
        host?.canvas(self, didTapObject: objectID, tapCount: tapCount)
    }

    func objectLayer(_ layer: ObjectLayerView, tapeWantsRevealed objectID: ObjectID, revealed: Bool) {
        host?.canvas(self, tapeWantsRevealed: objectID, revealed: revealed)
    }

    func objectLayer(_ layer: ObjectLayerView, textEditingBegan objectID: ObjectID) {
        host?.canvas(self, textEditingBegan: objectID)
    }

    func objectLayer(_ layer: ObjectLayerView, textEditingEnded objectID: ObjectID, text: String, fittingHeight: Double) {
        host?.canvas(self, textEditingEnded: objectID, text: text, fittingHeight: fittingHeight)
    }

    // MARK: Reading mode

    @objc private func handleReadingTap(_ gesture: UITapGestureRecognizer) {
        guard isReadingMode else { return }
        host?.canvas(self, readingModeTapAt: PagePoint(gesture.location(in: self)))
    }

    /// The PDF link annotation under a page-space point, if any.
    func linkAnnotation(at point: PagePoint) -> PDFAnnotation? {
        guard case .pdf(let source) = page.background, let loader,
              let document = loader.pdfDocuments.cachedDocument(for: source.assetID),
              let pdfPage = document.page(at: source.pageIndex) else { return nil }
        let user = mapping.pdfUserPoint(fromPage: point)
        guard let annotation = pdfPage.annotation(at: CGPoint(user)) else { return nil }
        let isLink = annotation.type == "Link" || annotation.url != nil || annotation.destination != nil || annotation.action != nil
        return isLink ? annotation : nil
    }
}

/// A non-live page: a cached thumbnail and the page number.
final class PagePlaceholderView: UIView {
    let pageID: PageID
    private let imageView = UIImageView()
    private let label = UILabel()
    private var requestedKey: String?

    init(pageID: PageID) {
        self.pageID = pageID
        super.init(frame: .zero)
        backgroundColor = .white
        isOpaque = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)
        imageView.contentMode = .scaleToFill
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.frame = bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(page: Page, pageNumber: Int, thumbnails: ThumbnailCache) {
        accessibilityLabel = "Page \(pageNumber)"
        label.text = "\(pageNumber)"
        label.isHidden = imageView.image != nil
        let size = CGSize(width: 240, height: max(1, 240 * page.size.height / max(page.size.width, 1)))
        let key = ThumbnailCache.key(for: page, size: size)
        if let cached = thumbnails.cachedImage(for: page, size: size) {
            imageView.image = cached
            label.isHidden = true
            requestedKey = key
            return
        }
        guard requestedKey != key else { return }
        requestedKey = key
        thumbnails.requestImage(for: page, size: size) { [weak self] image in
            guard let self, self.requestedKey == key, let image else { return }
            self.imageView.image = image
            self.label.isHidden = true
        }
    }
}


// MARK: - Ink canvas host

/// Holds the PencilKit canvas and answers `undoManager` with a private one.
///
/// PencilKit registers a per-stroke undo action on whatever `UndoManager` the
/// responder chain provides while a gesture runs. Those registrations are
/// superseded the moment the stroke is committed to the document, so they have
/// to be discarded — but the editor's own manager is what a `UITextView` in the
/// object layer uses, and emptying that would take a student's typing with it.
/// Giving the canvas its own manager keeps the two apart instead of papering
/// over the collision.
final class InkCanvasHostView: UIView {
    let inkUndoManager = UndoManager()
    override var undoManager: UndoManager? { inkUndoManager }
}

// MARK: - Unavailable ink

/// Shown over a page whose ink could not be loaded. It covers the ink layer
/// only: the PDF background, images and text boxes underneath stay visible and
/// usable, and the page's asset reference is left exactly as it was.
final class InkUnavailableView: UIView {
    var onRetry: (() -> Void)?
    var message: String = "" {
        didSet { label.text = message; accessibilityLabel = message }
    }

    private let label = UILabel()
    private let button = UIButton(type: .system)
    private let box = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true

        box.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.94)
        box.layer.cornerRadius = 12
        box.layer.borderWidth = 1
        box.layer.borderColor = UIColor.separator.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 0
        label.textAlignment = .center

        var config = UIButton.Configuration.borderedProminent()
        config.title = "Try Again"
        button.configuration = config
        button.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        let note = UILabel()
        note.font = .preferredFont(forTextStyle: .footnote)
        note.adjustsFontForContentSizeCategory = true
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        note.textAlignment = .center
        note.text = "Nothing has been changed. Writing on this page is paused so the original is not overwritten."

        let stack = UIStackView(arrangedSubviews: [label, note, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            box.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20),
        ])
        isAccessibilityElement = false
        accessibilityElements = [label, button]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Only the box takes touches; the rest of the page stays usable.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden else { return nil }
        let inBox = box.convert(box.bounds, to: self).contains(point)
        return inBox ? super.hitTest(point, with: event) : nil
    }
}
