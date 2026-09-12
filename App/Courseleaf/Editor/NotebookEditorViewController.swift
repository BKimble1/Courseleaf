import Foundation
import UIKit
import SwiftUI
import PencilKit
import PDFKit
import DocumentCore
import PageGeometry
import Editing
import Workspace

// The editor's top-level coordinator (docs/ARCHITECTURE.md sections 4, 6, 7, 8).
//
// It owns the scroll view, the page layout, the virtualized page view pool,
// the tool strip, the selection controller and the image insertion
// controller, and it is the single place where user gestures become
// `EditCommand`s on the open `DocumentSessioning`.
//
// Undo model. One `UndoManager` is shared with every hosted `PKCanvasView`
// through the responder chain (`undoManager` is overridden). The *document*
// is the undo authority: a finished stroke, a lasso move, a page insert and a
// text edit are each one grouped document operation (`session.performGrouped`),
// and undo/redo run `session.undo()` / `session.redo()`, after which the live
// canvases reload their ink from the document. PencilKit registers its own
// per-stroke actions on the shared manager while a gesture runs; those are
// discarded once the stroke has been committed as `replaceInk`, so there is
// exactly one undo stack and a stroke never undoes out of step with the page
// it belongs to.
@MainActor
final class NotebookEditorViewController: UIViewController {

    // MARK: Contract with the SwiftUI shell

    let session: any DocumentSessioning
    /// Called after ink was committed on a page so the app can queue recognition (§9).
    var onPageNeedsRecognition: ((PageID) -> Void)?
    /// Called when the focused page changes: the page and its zero-based index.
    var onCurrentPageChange: ((PageID, Int) -> Void)?
    /// Called when reading mode is toggled from inside the editor.
    var onReadingModeChange: ((Bool) -> Void)?

    // MARK: State

    private(set) var pageIDs: [PageID] = []
    private var pageSizes: [PageSize] = []
    private var indexByPageID: [PageID: Int] = [:]
    private(set) var currentPageIndex = 0
    private(set) var pageLayout = PageLayout(mode: .verticalContinuous, pageSizes: [])

    var isHorizontalPaging = false {
        didSet {
            guard isHorizontalPaging != oldValue else { return }
            editorToolbar.isHorizontalPaging = isHorizontalPaging
            rebuildLayout(keepingPageIndex: currentPageIndex)
        }
    }

    var isReadingMode = false {
        didSet {
            guard isReadingMode != oldValue else { return }
            selectionController.clearSelection()
            for canvas in liveCanvases {
                canvas.isReadingMode = isReadingMode
                canvas.drawingEnabled = !isReadingMode
            }
            editorToolbar.isReadingMode = isReadingMode
            updateChromeState()
            onReadingModeChange?(isReadingMode)
        }
    }

    var inputSettings: EditorInputSettings {
        didSet {
            guard inputSettings != oldValue else { return }
            applyInputSettings()
        }
    }

    var toolState: EditorToolState {
        didSet {
            guard toolState != oldValue else { return }
            toolStateStore.save(toolState)
            applyToolState()
        }
    }

    // MARK: Collaborators

    let loader: PageContentLoader
    let thumbnails: ThumbnailCache
    private let toolStateStore = EditorToolStateStore()
    private let editorUndoManager = UndoManager()
    private let selectionController = SelectionController()
    private let imageInsertion = ImageInsertionController()
    private var imageInsertionHost: EditorImageInsertionHost!
    private var pool: PageViewPool!
    private var colorPickerBridge: EditorColorPickerBridge?

    // MARK: Views

    private let scrollView = PageScrollView(frame: .zero)
    private let editorToolbar = EditorToolbar(frame: .zero)
    private let saveStatusView = SaveStatusView(frame: .zero)
    private let pageLabel = UILabel()
    private let barBackground = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let barStack = UIStackView()
    private let infoStack = UIStackView()

    // MARK: Bookkeeping

    private let initialPageID: PageID?
    private var hasPerformedInitialLayout = false
    private var lastLaidOutSize: CGSize = .zero
    private var assetIDByDigest: [String: AssetID] = [:]
    private var inkCommitTasks: [PageID: Task<Void, Never>] = [:]
    private var pendingInkPages: Set<PageID> = []
    private var pendingChangeSet = ChangeSet.empty
    private var changeFlushScheduled = false
    private var undoClearScheduled = false
    private var lastViewedRecordTask: Task<Void, Never>?
    private var highlightClearTask: Task<Void, Never>?
    private weak var navigatorViewController: PageNavigatorViewController?
    private var previousChangeHandler: ((ChangeSet) -> Void)?
    private var previousSaveStatusHandler: ((SaveStatus) -> Void)?
    private let now: () -> Date

    // MARK: Life cycle

    init(session: any DocumentSessioning, initialPageID: PageID?, inputSettings: EditorInputSettings = EditorInputSettings(),
         now: @escaping () -> Date = Date.init) {
        self.session = session
        self.initialPageID = initialPageID
        self.inputSettings = inputSettings
        self.now = now
        self.loader = PageContentLoader(assets: SessionAssetProvider(session: session))
        self.thumbnails = ThumbnailCache(loader: loader)
        var restored = EditorToolStateStore().load()
        // "Image" is a menu, never a persistent mode; fall back to the last pen.
        if restored.tool == .image { restored.select(.ink(restored.lastInkTool)) }
        self.toolState = restored
        super.init(nibName: nil, bundle: nil)
        for (id, asset) in session.editor.snapshot.assets {
            assetIDByDigest[Self.digestKey(asset.sha256, asset.mediaType)] = id
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        buildChrome()

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            barBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        pool = PageViewPool(
            liveLimit: 3,
            makeCanvas: { [unowned self] id in self.makeCanvas(for: id) },
            makePlaceholder: { id in PagePlaceholderView(pageID: id) })

        selectionController.host = self
        imageInsertionHost = EditorImageInsertionHost(controller: self)
        imageInsertion.host = imageInsertionHost

        previousChangeHandler = session.onChange
        session.onChange = { [weak self] changes in self?.handleDocumentChange(changes) }
        previousSaveStatusHandler = session.onSaveStatusChange
        session.onSaveStatusChange = { [weak self] status in self?.handleSaveStatus(status) }
        saveStatusView.onRetry = { [weak self] in self?.flushSoon() }
        saveStatusView.update(session.saveStatus)

        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)

        reloadDocumentStructure()
        applyToolState()
        applyInputSettings()
        updateChromeState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        commitAllPendingInk()
        recordLastViewedPageNow()
        flushSoon()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let compact = view.bounds.width < 620 || traitCollection.horizontalSizeClass == .compact
        if editorToolbar.isCompact != compact { editorToolbar.isCompact = compact }
        let bottomInset = barBackground.bounds.height
        if abs(scrollView.contentInset.bottom - bottomInset) > 0.5 { scrollView.contentInset.bottom = bottomInset }

        if !hasPerformedInitialLayout {
            hasPerformedInitialLayout = true
            lastLaidOutSize = view.bounds.size
            rebuildLayout(keepingPageIndex: nil)
            scrollView.zoomScale = fitToWidthZoom()
            let start = startIndex()
            scrollToPage(start, animated: false)
            setCurrentPageIndex(start, announce: false)
            updateVisiblePages()
        } else if view.bounds.size != lastLaidOutSize {
            lastLaidOutSize = view.bounds.size
            rebuildLayout(keepingPageIndex: currentPageIndex)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        thumbnails.removeAll()
        loader.decoded.removeAll()
    }

    // MARK: Chrome

    private func buildChrome() {
        barBackground.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(barBackground)

        pageLabel.font = .preferredFont(forTextStyle: .footnote)
        pageLabel.adjustsFontForContentSizeCategory = true
        pageLabel.textColor = .secondaryLabel
        pageLabel.textAlignment = .center
        pageLabel.accessibilityTraits = .staticText

        infoStack.axis = .vertical
        infoStack.alignment = .trailing
        infoStack.spacing = 2
        infoStack.addArrangedSubview(pageLabel)
        infoStack.addArrangedSubview(saveStatusView)
        infoStack.setContentHuggingPriority(.required, for: .horizontal)
        infoStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        editorToolbar.delegate = self
        editorToolbar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        barStack.axis = .horizontal
        barStack.alignment = .center
        barStack.spacing = 12
        barStack.translatesAutoresizingMaskIntoConstraints = false
        barBackground.contentView.addSubview(barStack)
        NSLayoutConstraint.activate([
            barStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            barStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            barStack.topAnchor.constraint(equalTo: barBackground.contentView.topAnchor, constant: 4),
            barStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
        arrangeBar()
    }

    /// Tools sit on the side the writing hand does not cover (A17): leading for
    /// right-handed students, trailing for left-handed ones.
    private func arrangeBar() {
        for subview in barStack.arrangedSubviews {
            barStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        let ordered: [UIView] = inputSettings.leftHanded ? [infoStack, editorToolbar] : [editorToolbar, infoStack]
        for subview in ordered { barStack.addArrangedSubview(subview) }
        infoStack.alignment = inputSettings.leftHanded ? .leading : .trailing
    }

    private func updateChromeState() {
        editorToolbar.canUndo = session.canUndo
        editorToolbar.canRedo = session.canRedo
        editorToolbar.isReadingMode = isReadingMode
        editorToolbar.isHorizontalPaging = isHorizontalPaging
        let count = max(pageIDs.count, 1)
        pageLabel.text = "Page \(min(currentPageIndex + 1, count)) of \(count)"
        pageLabel.accessibilityLabel = pageLabel.text
    }

    /// Live page canvases (at most `PageViewPool.liveLimit`, three by default).
    private var liveCanvases: [PageCanvasView] {
        guard let pool = pool else { return [] }
        return Array(pool.liveCanvases.values)
    }

    private func applyToolState() {
        editorToolbar.state = toolState
        let tool = toolState.pencilKitTool
        for canvas in liveCanvases {
            canvas.activeTool = toolState.tool
            canvas.setPencilKitTool(tool)
        }
    }

    private func applyInputSettings() {
        scrollView.setFingerDrawingEnabled(inputSettings.fingerDrawing)
        editorToolbar.isLeftHanded = inputSettings.leftHanded
        arrangeBar()
        let policy = inputSettings.drawingPolicy
        for canvas in liveCanvases { canvas.setDrawingPolicy(policy) }
    }

    // MARK: Document structure and layout

    private func reloadDocumentStructure() {
        let snapshot = session.editor.snapshot
        pageIDs = snapshot.document.pageIDs
        pageSizes = pageIDs.map { snapshot.pages[$0]?.size ?? snapshot.document.defaultPageSize }
        indexByPageID = Dictionary(pageIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        currentPageIndex = min(currentPageIndex, max(pageIDs.count - 1, 0))
    }

    private func startIndex() -> Int {
        if let initialPageID, let index = indexByPageID[initialPageID] { return index }
        let restored = session.editor.snapshot.document.lastViewedPageIndex
        return min(max(restored, 0), max(pageIDs.count - 1, 0))
    }

    private func rebuildLayout(keepingPageIndex index: Int?) {
        let mode: PageLayout.Mode
        if isHorizontalPaging {
            let zoom = max(Double(scrollView.zoomScale), 0.01)
            let width = max(Double(view.bounds.width), 1) / zoom
            let height = max(Double(view.bounds.height), 1) / zoom
            mode = .horizontalPaged(slotSize: PageSize(width: width, height: height))
        } else {
            mode = .verticalContinuous
        }
        pageLayout = PageLayout(mode: mode, pageSizes: pageSizes)
        scrollView.setLayoutMode(isHorizontalPaging: isHorizontalPaging)
        scrollView.layout = pageLayout
        positionPageViews()
        if let index { scrollToPage(index, animated: false) }
        updateVisiblePages()
    }

    private func fitToWidthZoom() -> CGFloat {
        let width = Double(scrollView.bounds.width)
        guard width > 0 else { return 1 }
        return CGFloat(EditorZoom.clamped(pageLayout.fitToWidthZoom(viewportWidth: width)))
    }

    func scrollToPage(_ index: Int, animated: Bool) {
        guard pageLayout.frames.indices.contains(index) else { return }
        let offset = pageLayout.contentOffset(showingPage: index,
                                              zoomScale: Double(scrollView.zoomScale),
                                              viewportSize: PageSize(scrollView.bounds.size))
        var point = CGPoint(offset)
        if scrollView.contentSize.width <= scrollView.bounds.width { point.x = -scrollView.contentInset.left }
        point.y = max(-scrollView.contentInset.top, point.y)
        scrollView.setContentOffset(point, animated: animated)
        if !animated { updateVisiblePages() }
    }

    func goToPage(_ pageID: PageID, animated: Bool) {
        guard let index = indexByPageID[pageID] else { return }
        scrollToPage(index, animated: animated)
        setCurrentPageIndex(index, announce: true)
    }

    // MARK: Virtualization

    private func makeCanvas(for id: PageID) -> PageCanvasView {
        let page = session.editor.page(id) ?? Page(id: id, size: session.editor.snapshot.document.defaultPageSize,
                                                   background: .template(.blank), revisionID: RevisionID(),
                                                   createdAt: now(), modifiedAt: now())
        let canvas = PageCanvasView(page: page, host: self, loader: loader)
        canvas.isReadingMode = isReadingMode
        canvas.drawingEnabled = !isReadingMode
        canvas.activeTool = toolState.tool
        canvas.setPencilKitTool(toolState.pencilKitTool)
        canvas.setDrawingPolicy(inputSettings.drawingPolicy)
        canvas.setDisplayZoom(scrollView.zoomScale, screenScale: screenScale)
        return canvas
    }

    private func updateVisiblePages() {
        guard pool != nil, !pageIDs.isEmpty else { return }
        let visible = scrollView.visibleContentRect
        guard visible.width > 0, visible.height > 0 else { return }
        let prefetch = visible.insetBy(dx: -visible.width * 0.4, dy: -visible.height * 0.6)
        let visibleIndices = pageLayout.indices(intersecting: PageRect(prefetch))
        let focus = pageLayout.focusIndex(forVisibleRect: PageRect(visible))
        let update = pool.update(pageIDs: pageIDs, visibleIndices: visibleIndices, focusIndex: focus)
        for canvas in update.evictedCanvases {
            // Never drop ink that has not reached the document yet.
            commitInkImmediately(canvas: canvas)
            selectionController.detach(from: canvas)
            canvas.removeFromSuperview()
        }
        for placeholder in update.removedPlaceholders { placeholder.removeFromSuperview() }
        for canvas in update.addedCanvases {
            scrollView.contentView.addSubview(canvas)
            selectionController.attach(to: canvas)
        }
        for placeholder in update.addedPlaceholders { scrollView.contentView.insertSubview(placeholder, at: 0) }
        positionPageViews()
        if let focus { setCurrentPageIndex(focus, announce: false) }
    }

    private func positionPageViews() {
        guard pool != nil else { return }
        let snapshot = session.editor.snapshot
        let total = pageIDs.count
        for (id, canvas) in pool.liveCanvases {
            guard let index = indexByPageID[id], pageLayout.frames.indices.contains(index) else { continue }
            let frame = CGRect(pageLayout.frames[index])
            if canvas.frame != frame { canvas.frame = frame }
            canvas.accessibilityLabel = "Page \(index + 1) of \(total)"
        }
        for (id, placeholder) in pool.placeholders {
            guard let index = indexByPageID[id], pageLayout.frames.indices.contains(index) else { continue }
            placeholder.frame = CGRect(pageLayout.frames[index])
            if let page = snapshot.pages[id] {
                placeholder.configure(page: page, pageNumber: index + 1, thumbnails: thumbnails)
            }
        }
    }

    private func setCurrentPageIndex(_ index: Int, announce: Bool) {
        guard index != currentPageIndex || pageLabel.text == nil else { return }
        currentPageIndex = index
        updateChromeState()
        navigatorViewController?.setCurrentPageIndex(index, scroll: true)
        scheduleLastViewedRecord()
        if let id = pageIDs[safe: index] { onCurrentPageChange?(id, index) }
        if announce { UIAccessibility.post(notification: .pageScrolled, argument: pageLabel.text) }
    }

    var currentPageID: PageID? { pageIDs[safe: currentPageIndex] }

    /// The page-space region of the current page that is on screen, for centring inserted content.
    var visiblePageRect: PageRect? {
        guard pageLayout.frames.indices.contains(currentPageIndex), let page = currentPageID.flatMap({ session.editor.page($0) }) else { return nil }
        let frame = pageLayout.frames[currentPageIndex]
        let visible = PageRect(scrollView.visibleContentRect).offsetBy(dx: -frame.minX, dy: -frame.minY)
        return visible.intersection(page.bounds) ?? page.bounds
    }

    private func scheduleLastViewedRecord() {
        lastViewedRecordTask?.cancel()
        let index = currentPageIndex
        lastViewedRecordTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.recordLastViewedPage(index)
        }
    }

    private func recordLastViewedPageNow() {
        lastViewedRecordTask?.cancel()
        recordLastViewedPage(currentPageIndex)
    }

    private func recordLastViewedPage(_ index: Int) {
        guard session.editor.snapshot.document.lastViewedPageIndex != index else { return }
        // `DocumentSession` also pokes the save scheduler; the protocol only exposes the editor.
        if let concrete = session as? DocumentSession {
            concrete.setLastViewedPageIndex(index)
        } else {
            session.editor.setLastViewedPageIndex(index)
        }
    }

    // MARK: Assets

    private static func digestKey(_ sha: String, _ type: AssetMediaType) -> String { "\(type.rawValue)|\(sha)" }

    @discardableResult
    private func registerAsset(data: Data, digest: String?, mediaType: AssetMediaType) -> AssetID {
        let sha = digest ?? EditorAssets.sha256Hex(data)
        let key = Self.digestKey(sha, mediaType)
        if let existing = assetIDByDigest[key] { return existing }
        let asset = SourceAsset(sha256: sha, mediaType: mediaType, byteCount: data.count, importedAt: now())
        session.addAsset(PendingAsset(asset: asset, data: data))
        assetIDByDigest[key] = asset.id
        return asset.id
    }

    // MARK: Ink commits

    /// A `PKDrawing` handed to a background task for serialization. The value is
    /// immutable; the box only states that to the compiler.
    private struct InkPayload: @unchecked Sendable {
        let drawing: PKDrawing
    }

    private func scheduleInkCommit(for canvas: PageCanvasView) {
        let pageID = canvas.pageID
        pendingInkPages.insert(pageID)
        inkCommitTasks[pageID]?.cancel()
        inkCommitTasks[pageID] = Task { [weak self] in
            // Debounce: a commit happens after the stroke ends, never per sample.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.commitInk(pageID: pageID)
        }
    }

    private func commitInk(pageID: PageID) async {
        inkCommitTasks[pageID] = nil
        guard pendingInkPages.contains(pageID), let canvas = pool.canvas(for: pageID) else { return }
        let drawing = canvas.drawing
        guard !drawing.strokes.isEmpty else {
            applyInkCommit(canvas: canvas, assetID: nil)
            return
        }
        // Serialization and hashing stay off the drawing path (§7).
        let payload = InkPayload(drawing: drawing)
        let encoded = await Task.detached(priority: .userInitiated) { () -> (Data, String) in
            let data = payload.drawing.dataRepresentation()
            return (data, EditorAssets.sha256Hex(data))
        }.value
        guard !Task.isCancelled, let liveCanvas = pool.canvas(for: pageID), pendingInkPages.contains(pageID) else { return }
        let assetID = registerAsset(data: encoded.0, digest: encoded.1, mediaType: .inkDrawing)
        applyInkCommit(canvas: liveCanvas, assetID: assetID)
    }

    /// Commits the canvas's current drawing right now (eviction, page change, leaving the editor).
    private func commitInkImmediately(canvas: PageCanvasView) {
        let pageID = canvas.pageID
        guard pendingInkPages.contains(pageID) else { return }
        inkCommitTasks[pageID]?.cancel()
        inkCommitTasks[pageID] = nil
        applyInkCommit(canvas: canvas, assetID: registerInkAsset(canvas.drawing))
    }

    private func commitAllPendingInk() {
        for pageID in pendingInkPages {
            guard let canvas = pool?.canvas(for: pageID) else { continue }
            commitInkImmediately(canvas: canvas)
        }
        pendingInkPages.removeAll()
    }

    private func applyInkCommit(canvas: PageCanvasView, assetID: AssetID?) {
        let pageID = canvas.pageID
        pendingInkPages.remove(pageID)
        guard let layerID = canvas.inkLayerID else { return }
        guard assetID != canvas.currentInkAssetID else { return }
        canvas.noteInkCommitted(assetID: assetID)
        performDocumentOperation("Draw") {
            try session.apply(.replaceInk(pageID, layerID, dataAssetID: assetID))
        }
        thumbnails.invalidate(pageID: pageID)
        onPageNeedsRecognition?(pageID)
    }

    // MARK: Undo

    override var undoManager: UndoManager? { editorUndoManager }

    /// PencilKit registers per-stroke undo on the shared manager while a gesture
    /// runs. The committed `replaceInk` command supersedes it, so the manager is
    /// emptied once the run loop that produced the change has finished.
    private func discardPencilKitUndoRegistrations() {
        guard !undoClearScheduled else { return }
        undoClearScheduled = true
        // Next run loop: any implicit per-event group has closed by then.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.undoClearScheduled = false
            self.clearUndoRegistrations()
        }
    }

    private func clearUndoRegistrations() {
        guard editorUndoManager.groupingLevel == 0,
              !editorUndoManager.isUndoing, !editorUndoManager.isRedoing else { return }
        editorUndoManager.removeAllActions()
    }

    func performUndo() {
        guard session.canUndo else { return }
        endActiveEditing()
        session.undo()
        clearUndoRegistrations()
        updateChromeState()
    }

    func performRedo() {
        guard session.canRedo else { return }
        endActiveEditing()
        session.redo()
        clearUndoRegistrations()
        updateChromeState()
    }

    private func endActiveEditing() {
        for canvas in liveCanvases {
            commitInkImmediately(canvas: canvas)
            canvas.objectLayer.endTextEditing()
        }
    }

    // MARK: Document operations

    func performDocumentOperation(_ name: String, _ body: () throws -> Void) {
        do {
            try session.performGrouped(name, body)
        } catch {
            presentEditingFailure(name: name, error: error)
        }
        editorUndoManager.setActionName(name)
        updateChromeState()
    }

    private func presentEditingFailure(name: String, error: Error) {
        let alert = UIAlertController(title: "\(name) Could Not Be Applied",
                                      message: Self.message(for: error),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private static func message(for error: Error) -> String {
        guard let editing = error as? EditingError else { return "\(error)" }
        switch editing {
        case .cannotDeleteLastPage: return "A notebook always keeps at least one page."
        case .objectLocked: return "That item is locked. Unlock it first."
        case .pageNotFound, .deletedPageNotFound: return "That page is no longer in this notebook."
        case .objectNotFound: return "That item is no longer on the page."
        default: return "The change could not be applied."
        }
    }

    // MARK: Change handling

    private func handleDocumentChange(_ changes: ChangeSet) {
        previousChangeHandler?(changes)
        pendingChangeSet.merge(changes)
        guard !changeFlushScheduled else { return }
        changeFlushScheduled = true
        // Applied after the current operation finishes so view updates never run
        // inside a grouped command (a lasso move applies several commands).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changeFlushScheduled = false
            self.flushDocumentChanges()
        }
    }

    private func flushDocumentChanges() {
        let changes = pendingChangeSet
        pendingChangeSet = .empty
        guard !changes.isEmpty else { return }
        let snapshot = session.editor.snapshot
        let newIDs = snapshot.document.pageIDs
        let newSizes = newIDs.map { snapshot.pages[$0]?.size ?? snapshot.document.defaultPageSize }
        let structureChanged = newIDs != pageIDs || newSizes != pageSizes
        pageIDs = newIDs
        pageSizes = newSizes
        indexByPageID = Dictionary(newIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        currentPageIndex = min(currentPageIndex, max(newIDs.count - 1, 0))

        for id in changes.changedPageIDs {
            thumbnails.invalidate(pageID: id)
            if let page = snapshot.pages[id] { pool?.canvas(for: id)?.apply(page: page) }
        }
        if structureChanged, hasPerformedInitialLayout {
            rebuildLayout(keepingPageIndex: nil)
        } else {
            positionPageViews()
            updateVisiblePages()
        }
        selectionController.refreshAfterDocumentChange(changedPageIDs: changes.changedPageIDs)
        navigatorViewController?.reload()
        updateChromeState()
    }

    private func handleSaveStatus(_ status: SaveStatus) {
        previousSaveStatusHandler?(status)
        saveStatusView.update(status)
    }

    private func flushSoon() {
        let session = self.session
        Task { try? await session.flush() }
    }

    @objc private func applicationWillResignActive() {
        commitAllPendingInk()
        recordLastViewedPageNow()
        flushSoon()
    }

    // MARK: Page navigator

    func presentPageNavigator() {
        guard presentedViewController == nil else { return }
        commitAllPendingInk()
        let session = self.session
        let navigator = PageNavigatorViewController(snapshotProvider: { session.editor.snapshot },
                                                    thumbnails: thumbnails, loader: loader)
        navigator.delegate = self
        navigatorViewController = navigator
        let navigation = UINavigationController(rootViewController: navigator)
        navigation.modalPresentationStyle = .formSheet
        let index = currentPageIndex
        present(navigation, animated: true) { [weak navigator] in
            navigator?.setCurrentPageIndex(index, scroll: true)
        }
    }

    private func dismissPageNavigator() {
        navigatorViewController = nil
        dismiss(animated: true)
    }

    // MARK: Search highlight

    /// Scrolls to `pageID` and flashes `region` (page space) on its overlay.
    func revealSearchHit(pageID: PageID, region: PageRect?) {
        goToPage(pageID, animated: true)
        highlightClearTask?.cancel()
        guard let region else { return }
        highlightClearTask = Task { [weak self] in
            // Wait for the page to become live before highlighting it.
            for _ in 0..<20 {
                guard !Task.isCancelled, let self else { return }
                if let canvas = self.canvas(for: pageID) {
                    canvas.overlay.highlightRect = CGRect(region)
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.canvas(for: pageID)?.overlay.highlightRect = nil
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let undo = UIKeyCommand(title: "Undo", action: #selector(handleUndoKey), input: "z", modifierFlags: .command)
        let redo = UIKeyCommand(title: "Redo", action: #selector(handleRedoKey), input: "z", modifierFlags: [.command, .shift])
        let zoomIn = UIKeyCommand(title: "Zoom In", action: #selector(handleZoomInKey), input: "+", modifierFlags: .command)
        let zoomInAlt = UIKeyCommand(action: #selector(handleZoomInKey), input: "=", modifierFlags: .command)
        let zoomOut = UIKeyCommand(title: "Zoom Out", action: #selector(handleZoomOutKey), input: "-", modifierFlags: .command)
        let zoomFit = UIKeyCommand(title: "Fit Width", action: #selector(handleZoomFitKey), input: "0", modifierFlags: .command)
        for command in [undo, redo, zoomIn, zoomInAlt, zoomOut, zoomFit] {
            command.wantsPriorityOverSystemBehavior = true
        }
        let selectAll = UIKeyCommand(title: "Select All", action: #selector(handleSelectAllKey), input: "a", modifierFlags: .command)
        let deselect = UIKeyCommand(action: #selector(handleEscapeKey), input: UIKeyCommand.inputEscape, modifierFlags: [])
        let next = UIKeyCommand(title: "Next Page", action: #selector(handleNextPageKey), input: UIKeyCommand.inputDownArrow, modifierFlags: [])
        let previous = UIKeyCommand(title: "Previous Page", action: #selector(handlePreviousPageKey), input: UIKeyCommand.inputUpArrow, modifierFlags: [])
        let nextRight = UIKeyCommand(action: #selector(handleNextPageKey), input: UIKeyCommand.inputRightArrow, modifierFlags: [])
        let previousLeft = UIKeyCommand(action: #selector(handlePreviousPageKey), input: UIKeyCommand.inputLeftArrow, modifierFlags: [])
        let pageDown = UIKeyCommand(action: #selector(handleNextPageKey), input: UIKeyCommand.inputPageDown, modifierFlags: [])
        let pageUp = UIKeyCommand(action: #selector(handlePreviousPageKey), input: UIKeyCommand.inputPageUp, modifierFlags: [])
        return [undo, redo, zoomIn, zoomInAlt, zoomOut, zoomFit, selectAll, deselect,
                next, previous, nextRight, previousLeft, pageDown, pageUp]
    }

    @objc private func handleUndoKey() { performUndo() }
    @objc private func handleRedoKey() { performRedo() }
    @objc private func handleZoomInKey() { applyZoom(scrollView.zoomScale * CGFloat(EditorZoom.step)) }
    @objc private func handleZoomOutKey() { applyZoom(scrollView.zoomScale / CGFloat(EditorZoom.step)) }
    @objc private func handleZoomFitKey() { applyZoom(fitToWidthZoom()) }
    @objc private func handleEscapeKey() { selectionController.clearSelection() }

    @objc private func handleSelectAllKey() {
        guard !isReadingMode, let id = currentPageID, let canvas = canvas(for: id) else { return }
        selectionController.selectAll(on: canvas)
    }

    @objc private func handleNextPageKey() { stepPage(by: 1) }
    @objc private func handlePreviousPageKey() { stepPage(by: -1) }

    private func stepPage(by delta: Int) {
        let target = min(max(currentPageIndex + delta, 0), max(pageIDs.count - 1, 0))
        guard target != currentPageIndex else { return }
        scrollToPage(target, animated: true)
        setCurrentPageIndex(target, announce: true)
    }

    private func applyZoom(_ zoom: CGFloat) {
        scrollView.setZoom(zoom, animated: true)
        updateDisplayZoom()
    }

    private func updateDisplayZoom() {
        let zoom = scrollView.zoomScale
        let scale = screenScale
        for canvas in liveCanvases { canvas.setDisplayZoom(zoom, screenScale: scale) }
    }
}

// MARK: - Scroll view

extension NotebookEditorViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { self.scrollView.contentView }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisiblePages()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        self.scrollView.centerContentIfNeeded()
        updateDisplayZoom()
        updateVisiblePages()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateDisplayZoom()
        if isHorizontalPaging { rebuildLayout(keepingPageIndex: currentPageIndex) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { recordLastViewedPageNow() }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { recordLastViewedPageNow() }
    }
}

// MARK: - Page canvases

extension NotebookEditorViewController: PageCanvasViewHost {
    func canvasDrawingDidChange(_ canvas: PageCanvasView) {
        guard !isReadingMode else { return }
        discardPencilKitUndoRegistrations()
        scheduleInkCommit(for: canvas)
        thumbnails.invalidate(pageID: canvas.pageID)
    }

    func canvasDidBeginUsingTool(_ canvas: PageCanvasView) {
        selectionController.clearSelection()
        canvas.objectLayer.endTextEditing()
        if let index = indexByPageID[canvas.pageID] { setCurrentPageIndex(index, announce: false) }
    }

    func canvas(_ canvas: PageCanvasView, tapeWantsRevealed id: ObjectID, revealed: Bool) {
        guard !isReadingMode else { return }
        performDocumentOperation(revealed ? "Reveal" : "Hide") {
            try session.apply(.setTapeRevealed(canvas.pageID, id, revealed))
        }
    }

    func canvas(_ canvas: PageCanvasView, didTapObject id: ObjectID, tapCount: Int) {
        guard !isReadingMode else { return }
        selectionController.objectTapped(id, on: canvas, tapCount: tapCount)
    }

    func canvas(_ canvas: PageCanvasView, textEditingBegan id: ObjectID) {
        if let index = indexByPageID[canvas.pageID] { setCurrentPageIndex(index, announce: false) }
    }

    func canvas(_ canvas: PageCanvasView, textEditingEnded id: ObjectID, text: String, fittingHeight: Double) {
        selectionController.textEditingEnded(objectID: id, text: text, fittingHeight: fittingHeight, canvas: canvas)
    }

    func canvas(_ canvas: PageCanvasView, readingModeTapAt point: PagePoint) {
        guard let annotation = canvas.linkAnnotation(at: point) else { return }
        if let url = annotation.url {
            UIApplication.shared.open(url)
            return
        }
        guard let destination = annotation.destination, let target = destination.page,
              let page = session.editor.page(canvas.pageID), case .pdf(let source) = page.background,
              let document = loader.pdfDocuments.cachedDocument(for: source.assetID) else { return }
        let targetIndex = document.index(for: target)
        guard let match = session.editor.snapshot.orderedPages.firstIndex(where: {
            if case .pdf(let other) = $0.background { return other.assetID == source.assetID && other.pageIndex == targetIndex }
            return false
        }) else { return }
        scrollToPage(match, animated: true)
        setCurrentPageIndex(match, announce: true)
    }
}

// MARK: - Selection

extension NotebookEditorViewController: SelectionControllerHost {
    var displayZoom: CGFloat { scrollView.zoomScale }

    var screenScale: CGFloat {
        let scale = traitCollection.displayScale
        return scale > 0 ? scale : 2
    }

    func canvas(for pageID: PageID) -> PageCanvasView? { pool?.canvas(for: pageID) }

    func registerInkAsset(_ drawing: PKDrawing) -> AssetID? {
        guard !drawing.strokes.isEmpty else { return nil }
        return registerAsset(data: drawing.dataRepresentation(), digest: nil, mediaType: .inkDrawing)
    }

    func registerImageAsset(data: Data, mediaType: AssetMediaType) -> AssetID {
        registerAsset(data: data, digest: nil, mediaType: mediaType)
    }

    func presentColorPicker(anchor: UIView, anchorRect: CGRect, current: RGBAColor, completion: @escaping (RGBAColor) -> Void) {
        let picker = UIColorPickerViewController()
        picker.selectedColor = UIColor(current)
        picker.supportsAlpha = false
        picker.title = "Color"
        let bridge = EditorColorPickerBridge(completion: completion)
        colorPickerBridge = bridge
        picker.delegate = bridge
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = anchor
        picker.popoverPresentationController?.sourceRect = anchorRect
        picker.popoverPresentationController?.permittedArrowDirections = [.up, .down]
        present(picker, animated: true)
    }

    func presentImageCrop(pageID: PageID, object: CanvasObject) {
        imageInsertion.presentCrop(pageID: pageID, object: object, loader: loader)
    }

    func selectionDidChange(_ selection: Selection?) {
        guard let selection, !selection.isEmpty else { return }
        let objectCount = selection.objectIDs.count
        let strokeCount = selection.strokeIndices.values.reduce(0) { $0 + $1.count }
        var parts: [String] = []
        if objectCount > 0 { parts.append("\(objectCount) item\(objectCount == 1 ? "" : "s")") }
        if strokeCount > 0 { parts.append("\(strokeCount) stroke\(strokeCount == 1 ? "" : "s")") }
        guard !parts.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: "Selected " + parts.joined(separator: " and "))
    }
}

// MARK: - Tool strip

extension NotebookEditorViewController: EditorToolbarDelegate {
    func toolbar(_ toolbar: EditorToolbar, didChangeState state: EditorToolState) {
        toolState = state
    }

    func toolbarDidTapUndo(_ toolbar: EditorToolbar) { performUndo() }

    func toolbarDidTapRedo(_ toolbar: EditorToolbar) { performRedo() }

    func toolbar(_ toolbar: EditorToolbar, insertImageFrom source: EditorToolbar.ImageSource) {
        switch source {
        case .photos: imageInsertion.presentPhotoPicker()
        case .camera: imageInsertion.presentCamera()
        case .files: imageInsertion.presentFilePicker()
        }
    }

    func toolbar(_ toolbar: EditorToolbar, requestsCustomColorFrom anchor: UIView, current: RGBAColor,
                 completion: @escaping (RGBAColor) -> Void) {
        presentColorPicker(anchor: anchor, anchorRect: anchor.bounds, current: current, completion: completion)
    }

    func toolbar(_ toolbar: EditorToolbar, requestsTextStyleFrom anchor: UIView) {
        let host = UIHostingController(rootView: TextStylePopoverView(style: toolState.textStyle) { [weak self] style in
            self?.applyTextStyle(style)
        })
        host.modalPresentationStyle = .popover
        host.preferredContentSize = CGSize(width: 340, height: 460)
        host.popoverPresentationController?.sourceView = anchor
        host.popoverPresentationController?.sourceRect = anchor.bounds
        host.popoverPresentationController?.delegate = self
        present(host, animated: true)
    }

    func toolbar(_ toolbar: EditorToolbar, didChooseLayout isHorizontalPaging: Bool) {
        self.isHorizontalPaging = isHorizontalPaging
    }

    func toolbarDidRequestClearPage(_ toolbar: EditorToolbar) {
        guard let pageID = currentPageID else { return }
        let alert = UIAlertController(title: "Clear This Page?",
                                      message: "Everything written or placed on the page is removed. You can undo this.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear Page", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.selectionController.clearSelection()
            self.pendingInkPages.remove(pageID)
            self.inkCommitTasks[pageID]?.cancel()
            self.inkCommitTasks[pageID] = nil
            self.canvas(for: pageID)?.setDrawing(PKDrawing(), assetID: nil)
            self.performDocumentOperation("Clear Page") {
                try self.session.apply(.clearPage(pageID))
            }
            self.thumbnails.invalidate(pageID: pageID)
        })
        present(alert, animated: true)
    }

    /// Applies a text style to the selected text object and keeps it as the default for new boxes.
    private func applyTextStyle(_ style: TextStyleDefaults) {
        var state = toolState
        state.textStyle = style
        state.noteColor(style.color)
        toolState = state
        guard let pageID = currentPageID, let page = session.editor.page(pageID) else { return }
        let selected = page.objects.filter { object in
            object.kind == .text && !object.isLocked && (selectionController.selection?.objectIDs.contains(object.id) ?? false)
        }
        guard !selected.isEmpty else { return }
        performDocumentOperation("Text Style") {
            for var object in selected {
                guard case .text(var content) = object.content else { continue }
                content.fontSize = style.fontSize
                content.weight = style.weight
                content.design = style.design
                content.alignment = style.alignment
                content.color = style.color
                object.content = .text(content)
                try session.apply(.updateObject(pageID, object))
            }
        }
    }
}

// MARK: - Page navigator delegate

extension NotebookEditorViewController: PageNavigatorDelegate {
    func navigator(_ navigator: PageNavigatorViewController, didSelectPageIndex index: Int) {
        dismissPageNavigator()
        scrollToPage(index, animated: false)
        setCurrentPageIndex(index, announce: true)
    }

    func navigator(_ navigator: PageNavigatorViewController, movePage id: PageID, to index: Int) {
        performDocumentOperation("Move Page") {
            try session.apply(.movePage(id, to: index))
        }
        flushDocumentChanges()
    }

    func navigator(_ navigator: PageNavigatorViewController, insertPageAfter index: Int, template: PaperTemplate?) {
        let page = session.editor.makeNewPage(template: template)
        let target = min(max(index + 1, 0), pageIDs.count)
        performDocumentOperation("Insert Page") {
            try session.apply(.insertPage(page, at: target))
        }
        flushDocumentChanges()
        scrollToPage(target, animated: false)
        setCurrentPageIndex(target, announce: true)
    }

    func navigator(_ navigator: PageNavigatorViewController, duplicatePageAt index: Int) {
        guard let id = pageIDs[safe: index], let copy = session.editor.makeDuplicate(of: id) else { return }
        performDocumentOperation("Duplicate Page") {
            try session.apply(.duplicatePage(source: id, copy: copy, at: index + 1))
        }
        flushDocumentChanges()
    }

    func navigator(_ navigator: PageNavigatorViewController, deletePageAt index: Int) {
        guard let id = pageIDs[safe: index] else { return }
        selectionController.clearSelection()
        performDocumentOperation("Delete Page") {
            try session.apply(.deletePage(id))
        }
        flushDocumentChanges()
    }

    func navigator(_ navigator: PageNavigatorViewController, restorePage id: PageID) {
        performDocumentOperation("Restore Page") {
            try session.apply(.restorePage(id))
        }
        flushDocumentChanges()
    }

    func navigator(_ navigator: PageNavigatorViewController, toggleBookmarkAt index: Int) {
        guard let id = pageIDs[safe: index], let page = session.editor.page(id) else { return }
        performDocumentOperation(page.isBookmarked ? "Remove Bookmark" : "Bookmark") {
            try session.apply(.setPageBookmark(id, !page.isBookmarked))
        }
        flushDocumentChanges()
    }

    func navigatorDidRequestClose(_ navigator: PageNavigatorViewController) {
        dismissPageNavigator()
    }
}

// MARK: - Presentation

extension NotebookEditorViewController: UIPopoverPresentationControllerDelegate {
    /// Keeps the text-style popover a popover at compact widths instead of a sheet.
    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}

// MARK: - Image insertion host

/// `ImageInsertionControllerHost` needs a non-optional `presentingViewController`,
/// which `UIViewController` already declares as optional, so the editor forwards
/// through this adapter instead of conforming directly.
@MainActor
final class EditorImageInsertionHost: ImageInsertionControllerHost {
    private unowned let controller: NotebookEditorViewController

    init(controller: NotebookEditorViewController) { self.controller = controller }

    var session: any DocumentSessioning { controller.session }
    var presentingViewController: UIViewController { controller }
    var currentPageID: PageID? { controller.currentPageID }
    var visiblePageRect: PageRect? { controller.visiblePageRect }

    func registerImageAsset(data: Data, mediaType: AssetMediaType) -> AssetID {
        controller.registerImageAsset(data: data, mediaType: mediaType)
    }

    func performDocumentOperation(_ name: String, _ body: () throws -> Void) {
        controller.performDocumentOperation(name, body)
    }

    func didInsertObject(_ id: ObjectID, on pageID: PageID) {
        controller.didInsertImageObject(id, on: pageID)
    }
}

extension NotebookEditorViewController {
    func didInsertImageObject(_ id: ObjectID, on pageID: PageID) {
        flushDocumentChanges()
        guard pool?.canvas(for: pageID) != nil else { return }
        selectionController.selectObject(id, on: pageID)
    }
}

// MARK: - Colour picker bridge

/// Keeps the completion handler alive for the lifetime of a `UIColorPickerViewController`.
@MainActor
final class EditorColorPickerBridge: NSObject, UIColorPickerViewControllerDelegate {
    private let completion: (RGBAColor) -> Void

    init(completion: @escaping (RGBAColor) -> Void) {
        self.completion = completion
        super.init()
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        guard !continuously else { return }
        completion(color.rgbaColor)
    }
}
