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
    /// Called when an explicit save could not complete, so the shell can say so.
    var onSaveFailure: ((Error) -> Void)?
    /// Called when the student chooses vertical or horizontal paging, so the
    /// choice is remembered rather than reset on the next notebook.
    var onScrollDirectionChange: ((Bool) -> Void)?

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
    let inkSerializer: any InkSerializing
    private let toolStateStore = EditorToolStateStore()
    /// The responder-chain manager. It carries text editing's own undo and a
    /// single bridging action into the document's history (see
    /// `refreshSystemUndoBridge`). PencilKit's per-stroke registrations never
    /// reach it: each canvas has its own (`InkCanvasHostView`).
    private let editorUndoManager = UndoManager()
    private let historyBridge = EditorHistoryBridge()
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
    private let initialHighlight: PageRect?
    private var hasPerformedInitialLayout = false
    private var lastLaidOutSize: CGSize = .zero
    private var assetIDByDigest: [String: AssetID] = [:]
    /// Debounce handles only. Correctness never depends on cancelling one:
    /// a commit that runs anyway is rejected by the page's drawing epoch.
    private var inkDebounceTasks: [PageID: Task<Void, Never>] = [:]
    /// One serial chain per page, so two quick strokes reach the document in
    /// the order they were drawn and become two undo steps, not one.
    private var inkCommitChains: [PageID: Task<Void, Never>] = [:]
    private var pendingChangeSet = ChangeSet.empty
    private var changeFlushScheduled = false
    private var undoClearScheduled = false
    private var shapeCandidate: ShapeCandidate?
    private var lastViewedRecordTask: Task<Void, Never>?
    private var highlightClearTask: Task<Void, Never>?
    private weak var navigatorViewController: PageNavigatorViewController?
    private var previousChangeHandler: ((ChangeSet) -> Void)?
    private var previousSaveStatusHandler: ((SaveStatus) -> Void)?
    private let now: () -> Date

    // MARK: Life cycle

    init(session: any DocumentSessioning, initialPageID: PageID?, inputSettings: EditorInputSettings = EditorInputSettings(),
         initialHighlight: PageRect? = nil,
         inkSerializer: any InkSerializing = DetachedInkSerializer(),
         now: @escaping () -> Date = Date.init) {
        self.session = session
        self.initialPageID = initialPageID
        self.initialHighlight = initialHighlight
        self.inputSettings = inputSettings
        self.inkSerializer = inkSerializer
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

    /// Hands the session's callbacks back to whoever had them. The editor chains
    /// onto `onChange` when it opens; without this the app's background
    /// recognition queue stays detached for the rest of the session once a
    /// notebook has been closed once. Called from SwiftUI's dismantle hook
    /// rather than `deinit`, which is not main-actor isolated.
    func detachFromSession() {
        if let previousChangeHandler { session.onChange = previousChangeHandler }
        if let previousSaveStatusHandler { session.onSaveStatusChange = previousSaveStatusHandler }
        previousChangeHandler = nil
        previousSaveStatusHandler = nil
        for canvas in liveCanvases { canvas.strokeSampler.clear() }
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
            barBackground.topAnchor.constraint(equalTo: view.topAnchor),
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

        historyBridge.controller = self
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
        // Leaving the editor is one of the moments the document has to match the
        // screen, so it goes through the same barrier export and printing use.
        endActiveEditing()
        recordLastViewedPageNow()
        flushSoon()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        // The page starts below the writing controls and never under them.
        let topInset = barBackground.bounds.height
        if abs(scrollView.chromeInsetTop - topInset) > 0.5 {
            let anchor = visiblePageAnchor()
            scrollView.chromeInsetTop = topInset
            restore(anchor: anchor)
        }
        editorToolbar.availableWidth = editorToolbar.bounds.width > 0 ? editorToolbar.bounds.width
            : view.bounds.width - 140

        if !hasPerformedInitialLayout {
            hasPerformedInitialLayout = true
            lastLaidOutSize = view.bounds.size
            rebuildLayout(keepingPageIndex: nil)
            scrollView.zoomScale = fitToWidthZoom()
            let start = startIndex()
            scrollToPage(start, animated: false)
            setCurrentPageIndex(start, announce: false)
            updateVisiblePages()
            // A search hit or a review item asked for a region, not just a page.
            if let highlight = initialHighlight, let id = pageIDs[safe: start] {
                revealSearchHit(pageID: id, region: highlight)
            }
        } else if view.bounds.size != lastLaidOutSize {
            // Rotation, a Split View drag, the keyboard appearing: keep the
            // student looking at the same place on the same page instead of
            // snapping back to the top of it.
            let anchor = visiblePageAnchor()
            lastLaidOutSize = view.bounds.size
            rebuildLayout(keepingPageIndex: nil)
            restore(anchor: anchor)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        thumbnails.removeAll()
        loader.decoded.removeAll()
    }

    // MARK: Chrome

    /// The writing controls live at the top, directly under the navigation bar,
    /// and stay there. They used to sit along the bottom edge, which is where a
    /// hand rests while writing and where a palm covers them; the page is also
    /// read from the top down, so chrome above it costs less of the page than
    /// chrome in the middle of the writing area.
    private func buildChrome() {
        barBackground.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(barBackground)

        pageLabel.font = .preferredFont(forTextStyle: .caption1)
        pageLabel.adjustsFontForContentSizeCategory = true
        pageLabel.textColor = .secondaryLabel
        pageLabel.textAlignment = .right
        pageLabel.accessibilityTraits = .staticText
        pageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        infoStack.axis = .vertical
        infoStack.alignment = .trailing
        infoStack.spacing = 0
        infoStack.addArrangedSubview(pageLabel)
        infoStack.addArrangedSubview(saveStatusView)
        infoStack.setContentHuggingPriority(.required, for: .horizontal)
        // Not `.required`: at an accessibility text size the page label would
        // otherwise refuse to give way and push the writing controls off the
        // bar. The toolbar scrolls; the label is what should shrink first.
        infoStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        editorToolbar.delegate = self
        editorToolbar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        editorToolbar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        barStack.axis = .horizontal
        barStack.alignment = .center
        barStack.spacing = 10
        barStack.translatesAutoresizingMaskIntoConstraints = false
        barBackground.contentView.addSubview(barStack)

        let hairline = UIView()
        hairline.backgroundColor = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        barBackground.contentView.addSubview(hairline)

        NSLayoutConstraint.activate([
            barStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            barStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            barStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            barStack.bottomAnchor.constraint(equalTo: barBackground.contentView.bottomAnchor, constant: -2),
            hairline.leadingAnchor.constraint(equalTo: barBackground.contentView.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: barBackground.contentView.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: barBackground.contentView.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)),
        ])
        arrangeBar()
    }

    /// Handedness moves the info column to the side the writing hand does not
    /// cover. It does not reverse the tools: a control order that flips when a
    /// student ticks "left-handed" is a different toolbar, not a mirrored one.
    private func arrangeBar() {
        for subview in barStack.arrangedSubviews {
            barStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        let ordered: [UIView] = inputSettings.leftHanded ? [infoStack, editorToolbar] : [editorToolbar, infoStack]
        for subview in ordered { barStack.addArrangedSubview(subview) }
        infoStack.alignment = inputSettings.leftHanded ? .leading : .trailing
        editorToolbar.isLeftHanded = inputSettings.leftHanded
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

    // MARK: Keeping the student's place

    /// Where the student is looking, in page space. Page index and scroll offset
    /// both change when the layout does; the page and the point inside it do not.
    struct PageAnchor {
        var pageID: PageID
        /// Point of the page at the top-left of the unobscured viewport.
        var pagePoint: PagePoint
        var zoom: CGFloat
    }

    func visiblePageAnchor() -> PageAnchor? {
        guard let id = currentPageID, let index = indexByPageID[id],
              pageLayout.frames.indices.contains(index) else { return nil }
        let frame = pageLayout.frames[index]
        let visible = scrollView.unobscuredContentRect
        return PageAnchor(pageID: id,
                          pagePoint: PagePoint(x: visible.minX - frame.minX, y: visible.minY - frame.minY),
                          zoom: scrollView.zoomScale)
    }

    func restore(anchor: PageAnchor?) {
        guard let anchor, let index = indexByPageID[anchor.pageID],
              pageLayout.frames.indices.contains(index) else { return }
        let frame = pageLayout.frames[index]
        let zoom = scrollView.zoomScale
        var offset = CGPoint(x: (frame.minX + anchor.pagePoint.x) * zoom,
                             y: (frame.minY + anchor.pagePoint.y) * zoom - scrollView.chromeInsetTop)
        let maxX = max(-scrollView.contentInset.left, scrollView.contentSize.width - scrollView.bounds.width)
        let maxY = max(-scrollView.contentInset.top, scrollView.contentSize.height - scrollView.bounds.height)
        offset.x = min(max(offset.x, -scrollView.contentInset.left), maxX)
        offset.y = min(max(offset.y, -scrollView.contentInset.top), maxY)
        scrollView.setContentOffset(offset, animated: false)
        setCurrentPageIndex(index, announce: false)
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
        canvas.strokeSampler.onHold = { [weak self, weak canvas] sampler in
            guard let self, let canvas else { return }
            self.handleStrokeHold(sampler, on: canvas)
        }
        canvas.strokeSampler.onAdjust = { [weak self, weak canvas] sampler in
            guard let self, let canvas else { return }
            self.handleStrokeAdjust(sampler, on: canvas)
        }
        return canvas
    }

    private func updateVisiblePages() {
        guard pool != nil, !pageIDs.isEmpty else { return }
        let visible = scrollView.unobscuredContentRect
        guard visible.width > 0, visible.height > 0 else { return }
        let prefetch = visible.insetBy(dx: -visible.width * 0.4, dy: -visible.height * 0.6)
        let visibleIndices = pageLayout.indices(intersecting: PageRect(prefetch))
        let focus = pageLayout.focusIndex(forVisibleRect: PageRect(visible))
        let update = pool.update(pageIDs: pageIDs, visibleIndices: visibleIndices, focusIndex: focus)
        for canvas in update.evictedCanvases {
            // Never drop ink that has not reached the document yet. With a
            // commit queued at every gesture boundary this is usually already
            // clean, so the synchronous encode is a rare fallback rather than
            // part of scrolling.
            commitInkImmediately(canvas: canvas)
            forgetInkState(for: canvas.pageID)
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

    /// Safety net for drawing changes that arrive without a gesture ending
    /// (PencilKit's own undo, for instance). The *undo boundary* is the end of
    /// a gesture, not this timer: the timer only bounds how long a change can
    /// sit in a view without reaching the document.
    static let inkCommitDebounce: TimeInterval = 0.3

    /// Queues a commit of `canvas`'s drawing. `atGestureBoundary` means a
    /// pen-down-to-pen-up gesture just ended, which is where an undo step ends.
    private func scheduleInkCommit(for canvas: PageCanvasView, atGestureBoundary: Bool) {
        let pageID = canvas.pageID
        inkDebounceTasks[pageID]?.cancel()
        inkDebounceTasks[pageID] = nil
        guard !atGestureBoundary else {
            enqueueInkCommit(for: canvas)
            return
        }
        inkDebounceTasks[pageID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.inkCommitDebounce * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.inkDebounceTasks[pageID] = nil
            guard let canvas = self.pool?.canvas(for: pageID) else { return }
            // Still drawing: the gesture's own end is the boundary, and
            // committing here would split one stroke into two undo steps
            // because the student paused in the middle of it.
            guard !canvas.isUsingTool else {
                self.scheduleInkCommit(for: canvas, atGestureBoundary: false)
                return
            }
            self.enqueueInkCommit(for: canvas)
        }
    }

    /// Takes a snapshot of the page's drawing and chains its serialization
    /// behind any snapshot already queued for that page, so results are applied
    /// in the order they were taken.
    private func enqueueInkCommit(for canvas: PageCanvasView) {
        guard canvas.hasUncommittedDrawing else { return }
        let pageID = canvas.pageID
        let generation = canvas.drawingGeneration
        let epoch = canvas.drawingEpoch
        let drawing = canvas.drawing
        let previous = inkCommitChains[pageID]
        inkCommitChains[pageID] = Task { [weak self] in
            await previous?.value
            await self?.commitInk(pageID: pageID, drawing: drawing, generation: generation, epoch: epoch)
        }
    }

    /// Serializes one snapshot and writes it to the document — unless the page's
    /// drawing was re-established in the meantime, in which case the snapshot
    /// describes ink that no longer exists and is thrown away. Nothing about
    /// this depends on having cancelled a task: a stale result that runs to
    /// completion still writes nothing and still leaves the page marked dirty,
    /// so the newer snapshot behind it is the one that lands.
    private func commitInk(pageID: PageID, drawing: PKDrawing, generation: Int, epoch: Int) async {
        guard let canvas = pool?.canvas(for: pageID), canvas.drawingEpoch == epoch,
              generation > canvas.committedDrawingGeneration else { return }
        var assetID: AssetID?
        if !drawing.strokes.isEmpty {
            let encoded = await inkSerializer.encode(drawing)
            guard let live = pool?.canvas(for: pageID), live === canvas, live.drawingEpoch == epoch,
                  generation > live.committedDrawingGeneration else { return }
            assetID = registerAsset(data: encoded.data, digest: encoded.sha256, mediaType: .inkDrawing)
        }
        applyInkCommit(canvas: canvas, assetID: assetID, generation: generation)
    }

    /// Commits the canvas's current drawing right now, on the main actor
    /// (eviction, page change, export, undo, leaving the editor). It closes the
    /// page's drawing epoch, so any serialization still running in the
    /// background is discarded instead of landing on top afterwards.
    @discardableResult
    private func commitInkImmediately(canvas: PageCanvasView) -> Bool {
        inkDebounceTasks[canvas.pageID]?.cancel()
        inkDebounceTasks[canvas.pageID] = nil
        guard canvas.hasUncommittedDrawing else { return false }
        let generation = canvas.drawingGeneration
        let drawing = canvas.drawing
        canvas.closeDrawingEpoch()
        let assetID = drawing.strokes.isEmpty ? nil : registerInkAsset(drawing)
        applyInkCommit(canvas: canvas, assetID: assetID, generation: generation)
        return true
    }

    @discardableResult
    private func commitAllPendingInk() -> Bool {
        var committed = false
        for canvas in liveCanvases where commitInkImmediately(canvas: canvas) { committed = true }
        return committed
    }

    /// How many pages currently have a live `PKCanvasView`. The pool bounds
    /// this; the performance profile asserts the bound holds after scrolling.
    var livePageCanvasCount: Int { pool?.liveCanvasCount ?? 0 }

    /// True when a live page is holding ink the document has not been told about.
    var hasUncommittedInk: Bool { liveCanvases.contains(where: \.hasUncommittedDrawing) }

    private func applyInkCommit(canvas: PageCanvasView, assetID: AssetID?, generation: Int) {
        let pageID = canvas.pageID
        guard session.editor.page(pageID) != nil else {
            // The page was deleted while this was in flight. Writing to it would
            // throw and put an alert in front of the student about a page they
            // just chose to remove.
            canvas.noteInkCommitted(assetID: canvas.currentInkAssetID, generation: generation)
            return
        }
        guard let layerID = canvas.inkLayerID else {
            // Nowhere to write it: the page has no ink layer, so there is
            // nothing outstanding for this page and no reason to keep retrying.
            canvas.noteInkCommitted(assetID: canvas.currentInkAssetID, generation: generation)
            return
        }
        guard assetID != canvas.currentInkAssetID else {
            // Round-tripped to the ink the document already holds. Mark it
            // committed anyway — leaving it dirty would spin forever.
            canvas.noteInkCommitted(assetID: assetID, generation: generation)
            return
        }
        canvas.noteInkCommitted(assetID: assetID, generation: generation)
        performDocumentOperation("Draw") {
            try session.apply(.replaceInk(pageID, layerID, dataAssetID: assetID))
        }
        thumbnails.invalidate(pageID: pageID)
        onPageNeedsRecognition?(pageID)
    }

    /// Drops everything queued for a page that no longer exists.
    private func forgetInkState(for pageID: PageID) {
        inkDebounceTasks[pageID]?.cancel()
        inkDebounceTasks[pageID] = nil
        inkCommitChains[pageID]?.cancel()
        inkCommitChains[pageID] = nil
    }

    // MARK: Edit barrier

    /// The one place that finishes everything held only in UIKit views and then
    /// makes the document durable. Export, printing, destructive page
    /// operations, leaving the editor and backgrounding all go through it,
    /// because `session.flush()` on its own cannot see a stroke that is still
    /// only in a `PKCanvasView` or a word still only in a `UITextView`.
    ///
    /// Returns nil on success, or the error that stopped the save.
    @discardableResult
    func prepareForDocumentSnapshot() async -> Error? {
        endActiveEditing()
        flushDocumentChanges()
        // Anything already queued for serialization has to land before the
        // snapshot is taken; `endActiveEditing` closed every live page's epoch,
        // so these chains resolve to no-ops, but waiting keeps the ordering honest.
        let chains = Array(inkCommitChains.values)
        for chain in chains { await chain.value }
        do {
            try await session.flush()
            return nil
        } catch {
            return error
        }
    }

    // MARK: Undo

    override var undoManager: UndoManager? { editorUndoManager }

    /// PencilKit registers a per-stroke undo action while a gesture runs. Those
    /// registrations live on each canvas's own manager (`InkCanvasHostView`),
    /// never on the editor's, and are superseded the moment the stroke is
    /// committed as a `replaceInk` command — so they are discarded there and
    /// nowhere else. Text editing's undo, on the editor's manager, is untouched.
    private func discardInkUndoRegistrations() {
        guard !undoClearScheduled else { return }
        undoClearScheduled = true
        // Next run loop: any implicit per-event group has closed by then.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.undoClearScheduled = false
            self.clearInkUndoRegistrations()
        }
    }

    private func clearInkUndoRegistrations() {
        for canvas in liveCanvases {
            let manager = canvas.canvasHost.inkUndoManager
            guard manager.groupingLevel == 0, !manager.isUndoing, !manager.isRedoing else { continue }
            manager.removeAllActions()
        }
    }

    /// Undo, from every entry point: ⌘Z, the toolbar, the Edit menu and the
    /// three-finger swipe. Pending ink is committed *first*, so the stroke that
    /// was just finished is in the history before we ask whether there is any.
    /// Checking `canUndo` before committing was why a first stroke could not be
    /// undone until the save debounce happened to have fired.
    func performUndo() {
        endActiveEditing()
        defer { refreshSystemUndoBridge(); updateChromeState() }
        guard session.canUndo else { return }
        session.undo()
        discardInkUndoRegistrations()
    }

    /// Redo after `endActiveEditing` may find nothing left to redo, because
    /// committing the stroke the student had just drawn is a new edit and a new
    /// edit clears the redo stack. That is the right answer; the `defer` is
    /// what stops the button from going on claiming otherwise.
    func performRedo() {
        endActiveEditing()
        defer { refreshSystemUndoBridge(); updateChromeState() }
        guard session.canRedo else { return }
        session.redo()
        discardInkUndoRegistrations()
    }

    /// Finishes anything a UIKit view is still holding: the text box being
    /// typed into and every page's uncommitted ink.
    private func endActiveEditing() {
        for canvas in liveCanvases {
            canvas.objectLayer.endTextEditing()
            commitInkImmediately(canvas: canvas)
        }
    }

    /// Keeps the responder-chain manager in step with the document's history so
    /// the Edit menu and the iPad three-finger swipe step the same stack the
    /// toolbar and ⌘Z do. It stores no edit of its own: at most one action,
    /// which asks the document to step and is re-armed afterwards.
    private func refreshSystemUndoBridge() {
        guard editorUndoManager.groupingLevel == 0 else { return }
        if editorUndoManager.isUndoing {
            if session.canRedo {
                editorUndoManager.registerUndo(withTarget: historyBridge) { bridge in bridge.redo() }
            }
            return
        }
        if editorUndoManager.isRedoing {
            if session.canUndo {
                editorUndoManager.registerUndo(withTarget: historyBridge) { bridge in bridge.undo() }
            }
            return
        }
        editorUndoManager.removeAllActions(withTarget: historyBridge)
        guard session.canUndo else { return }
        editorUndoManager.registerUndo(withTarget: historyBridge) { bridge in bridge.undo() }
        editorUndoManager.setActionName(session.editor.undoActionName ?? "Change")
    }

    // MARK: Standard edit actions

    @objc func undo(_ sender: Any?) { performUndo() }
    @objc func redo(_ sender: Any?) { performRedo() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(undo(_:)) { return isEditingText ? false : session.canUndo }
        if action == #selector(redo(_:)) { return isEditingText ? false : session.canRedo }
        return super.canPerformAction(action, withSender: sender)
    }

    /// True while a text box is being typed into. Page and history shortcuts
    /// stand down so the keyboard's own cursor movement and undo still work.
    var isEditingText: Bool {
        liveCanvases.contains { $0.objectLayer.editingTextID != nil }
    }

    // MARK: Document operations

    func performDocumentOperation(_ name: String, _ body: () throws -> Void) {
        do {
            try session.performGrouped(name, body)
        } catch {
            presentEditingFailure(name: name, error: error)
        }
        refreshSystemUndoBridge()
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

    /// Applies a pending document change to the views now rather than on the
    /// next run loop. The coalescing is deliberate — a grouped command should
    /// redraw once — so this exists for tests and for the places that must see
    /// the result before they continue.
    func applyPendingViewUpdatesNow() { flushDocumentChanges() }

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
        Task { [weak self] in
            guard let self else { return }
            if let error = await self.prepareForDocumentSnapshot() { self.noteSaveFailure(error) }
        }
    }

    /// A failed save is never silent: the badge already shows the scheduler's
    /// status, and this keeps the retry affordance honest for failures raised
    /// by an explicit flush rather than by the scheduler.
    private func noteSaveFailure(_ error: Error) {
        saveStatusView.update(session.saveStatus)
        onSaveFailure?(error)
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
        // While a text box is being typed into, the keyboard belongs to it:
        // arrows move the cursor and ⌘Z undoes typing. Registering page and
        // history commands here would take both away.
        guard !isEditingText else { return nil }
        let undo = UIKeyCommand(title: "Undo", action: #selector(handleUndoKey), input: "z", modifierFlags: .command)
        let redo = UIKeyCommand(title: "Redo", action: #selector(handleRedoKey), input: "z", modifierFlags: [.command, .shift])
        let zoomIn = UIKeyCommand(title: "Zoom In", action: #selector(handleZoomInKey), input: "+", modifierFlags: .command)
        let zoomInAlt = UIKeyCommand(action: #selector(handleZoomInKey), input: "=", modifierFlags: .command)
        let zoomOut = UIKeyCommand(title: "Zoom Out", action: #selector(handleZoomOutKey), input: "-", modifierFlags: .command)
        let zoomFit = UIKeyCommand(title: "Fit Width", action: #selector(handleZoomFitKey), input: "0", modifierFlags: .command)
        for command in [undo, redo, zoomIn, zoomInAlt, zoomOut, zoomFit] {
            command.wantsPriorityOverSystemBehavior = true
        }
        // Tool shortcuts, which PRODUCT_SPEC §3.2 and F018 have claimed for a
        // while without anything implementing them. Command-modified so they
        // cannot be confused with typing, and the guard above means they stand
        // down entirely while a text box has the keyboard.
        let toolKeys: [(String, EditorTool, String)] = [
            ("1", .ink(.pen), "Pen"), ("2", .ink(.pencil), "Pencil"), ("3", .ink(.highlighter), "Highlighter"),
            ("4", .eraser, "Eraser"), ("5", .lasso, "Lasso"), ("6", .shape(toolState.lastShapeKind), "Shape"),
        ]
        let toolCommands = toolKeys.map { input, tool, title -> UIKeyCommand in
            let command = UIKeyCommand(title: title, action: #selector(handleToolKey(_:)), input: input,
                                       modifierFlags: .command, propertyList: input)
            command.wantsPriorityOverSystemBehavior = true
            return command
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
                next, previous, nextRight, previousLeft, pageDown, pageUp] + toolCommands
    }

    @objc private func handleToolKey(_ sender: UIKeyCommand) {
        guard !isReadingMode, let input = sender.propertyList as? String else { return }
        let tool: EditorTool
        switch input {
        case "1": tool = .ink(.pen)
        case "2": tool = .ink(.pencil)
        case "3": tool = .ink(.highlighter)
        case "4": tool = .eraser
        case "5": tool = .lasso
        case "6": tool = .shape(toolState.lastShapeKind)
        default: return
        }
        var state = toolState
        state.select(tool)
        toolState = state
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
        discardInkUndoRegistrations()
        // Not a boundary: the gesture may still be running. The timer is only a
        // backstop for changes that arrive without one (PencilKit's own undo).
        scheduleInkCommit(for: canvas, atGestureBoundary: false)
        thumbnails.invalidate(pageID: canvas.pageID)
    }

    func canvasDidBeginUsingTool(_ canvas: PageCanvasView) {
        selectionController.clearSelection()
        canvas.objectLayer.endTextEditing()
        if let index = indexByPageID[canvas.pageID] { setCurrentPageIndex(index, announce: false) }
        shapeCandidate = nil
        canvas.hideShapePreview()
        canvas.strokeCountAtGestureStart = canvas.drawing.strokes.count
    }

    func canvasDidEndUsingTool(_ canvas: PageCanvasView) {
        let samples = canvas.strokeSampler.samples
        let candidate = shapeCandidate
        canvas.strokeSampler.clear()
        shapeCandidate = nil
        canvas.hideShapePreview()
        guard !isReadingMode else { return }
        // A finished gesture is an undo boundary, whatever the save timer is
        // doing. The two gestures get first refusal on it; if neither claims it,
        // it is committed as ordinary ink.
        if applyShapeCorrection(candidate, on: canvas) { return }
        if applyScribbleErase(samples: samples, on: canvas) { return }
        scheduleInkCommit(for: canvas, atGestureBoundary: true)
    }

    // MARK: Pen gestures

    /// A shape offered while the pen is still down. `base` is the fit taken at
    /// the moment of the hold; `shape` is that fit after any dragging since.
    private struct ShapeCandidate {
        var pageID: PageID
        var base: RecognizedShape
        var shape: RecognizedShape
        var anchor: PagePoint
        var confidence: Double
    }

    var shapeSettings: ShapeCorrectionSettings {
        var settings = ShapeCorrectionSettings()
        settings.snapsLinesToAxis = inputSettings.snapsShapesToAxis
        settings.snapsEqualSides = inputSettings.snapsShapesToAxis
        return settings
    }

    var scribbleEraseSettings: ScribbleEraseSettings { ScribbleEraseSettings() }

    /// Tools scribble erase is offered for. Deliberately short: a highlighter
    /// crossing a word out is how a student highlights, and an eraser is
    /// already an eraser.
    static let scribbleEraseTools: Set<InkToolKind> = [.pen, .pencil]

    private func handleStrokeHold(_ sampler: StrokeSamplingGestureRecognizer, on canvas: PageCanvasView) {
        guard inputSettings.shapeCorrection, !isReadingMode, case .ink = toolState.tool else { return }
        guard shapeCandidate == nil else { return }
        let points = sampler.samplesAtHold.map(\.location)
        guard let anchor = points.first,
              let recognition = ShapeRecognizer.recognize(points, settings: shapeSettings) else { return }
        shapeCandidate = ShapeCandidate(pageID: canvas.pageID, base: recognition.shape,
                                        shape: recognition.shape, anchor: anchor,
                                        confidence: recognition.confidence)
        showShapePreview(on: canvas)
        UIAccessibility.post(notification: .announcement,
                             argument: "\(Self.shapeName(recognition.shape)) ready. Lift the pen to use it.")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func handleStrokeAdjust(_ sampler: StrokeSamplingGestureRecognizer, on canvas: PageCanvasView) {
        guard var candidate = shapeCandidate, candidate.pageID == canvas.pageID,
              let current = sampler.currentPoint else { return }
        guard let adjusted = ShapeAdjustment.dragging(candidate.base, anchor: candidate.anchor,
                                                      to: current, settings: shapeSettings) else {
            // Dragged back down to nothing: that is how the correction is
            // cancelled without lifting. The stroke as drawn is kept.
            shapeCandidate = nil
            canvas.hideShapePreview()
            return
        }
        candidate.shape = adjusted
        shapeCandidate = candidate
        showShapePreview(on: canvas)
    }

    private func showShapePreview(on canvas: PageCanvasView) {
        guard let candidate = shapeCandidate else { return }
        let preset = toolState.preset(for: toolState.lastInkTool)
        canvas.showShapePreview(candidate.shape, color: UIColor(preset.color), width: CGFloat(preset.width))
    }

    static func shapeName(_ shape: RecognizedShape) -> String {
        switch shape {
        case .line: return "Straight line"
        case .ellipse(_, let a, let b, _): return abs(a - b) < 0.001 ? "Circle" : "Ellipse"
        case .rectangle(let corners):
            guard corners.count == 4 else { return "Rectangle" }
            let side = corners[0].distance(to: corners[1])
            let other = corners[1].distance(to: corners[2])
            return abs(side - other) < 0.001 ? "Square" : "Rectangle"
        }
    }

    /// Replaces the stroke the gesture just drew with the corrected shape, as
    /// ordinary ink in the same tool. Nothing new is persisted: the shape is a
    /// `PKStroke` like any other, so it erases, lassos, exports and prints the
    /// way handwriting does.
    private func applyShapeCorrection(_ candidate: ShapeCandidate?, on canvas: PageCanvasView) -> Bool {
        guard let candidate, candidate.pageID == canvas.pageID else { return false }
        let drawing = canvas.drawing
        guard drawing.strokes.count == canvas.strokeCountAtGestureStart + 1,
              let raw = drawing.strokes.last else { return false }
        let width = raw.path.first?.size.width ?? CGFloat(toolState.preset(for: toolState.lastInkTool).width)
        guard let corrected = InkStrokeBuilder.stroke(along: candidate.shape.polyline(), ink: raw.ink, width: width) else {
            return false
        }
        var strokes = Array(drawing.strokes.dropLast())
        strokes.append(corrected)
        commitReplacementDrawing(PKDrawing(strokes: strokes), on: canvas, named: Self.shapeName(candidate.shape))
        return true
    }

    /// Crossing existing handwriting out with the pen erases it. The decision is
    /// `ScribbleEraseRecognizer`'s; this only supplies the page's strokes as
    /// geometry and applies the result as one undoable operation.
    private func applyScribbleErase(samples: [StrokeSample], on canvas: PageCanvasView) -> Bool {
        guard inputSettings.scribbleErase, !isReadingMode, !samples.isEmpty else { return false }
        guard case .ink(let kind) = toolState.tool, Self.scribbleEraseTools.contains(kind) else { return false }
        let drawing = canvas.drawing
        guard drawing.strokes.count == canvas.strokeCountAtGestureStart + 1 else { return false }
        let scribbleIndex = drawing.strokes.count - 1
        let targets = canvas.inkTargets().filter { $0.index != scribbleIndex }
        guard !targets.isEmpty else { return false }
        let preset = toolState.preset(for: kind)
        let decision = ScribbleEraseRecognizer.decide(samples: samples, targets: targets,
                                                      gestureHalfWidth: preset.width / 2,
                                                      settings: scribbleEraseSettings)
        guard case .erase(let indices) = decision.verdict, !indices.isEmpty else { return false }
        // The command scribble goes with the strokes it crossed out, so undo
        // restores the page as it was and never leaves the scribble behind.
        let remaining = PencilKitDrawing(drawing: drawing).removingStrokes(indices + [scribbleIndex])
        commitReplacementDrawing(remaining.drawing, on: canvas, named: "Erase")
        UIAccessibility.post(notification: .announcement,
                             argument: "Erased \(indices.count) stroke\(indices.count == 1 ? "" : "s")")
        return true
    }

    /// Writes a whole replacement drawing for a page in one grouped document
    /// operation, so the change is exactly one undo step.
    private func commitReplacementDrawing(_ drawing: PKDrawing, on canvas: PageCanvasView, named name: String) {
        guard let layerID = canvas.inkLayerID else { return }
        inkDebounceTasks[canvas.pageID]?.cancel()
        inkDebounceTasks[canvas.pageID] = nil
        let assetID = drawing.strokes.isEmpty ? nil : registerInkAsset(drawing)
        performDocumentOperation(name) {
            try session.apply(.replaceInk(canvas.pageID, layerID, dataAssetID: assetID))
        }
        // Marks the canvas clean and closes its epoch, so any serialization
        // already running for this page is discarded instead of landing after.
        canvas.setDrawing(drawing, assetID: assetID)
        thumbnails.invalidate(pageID: canvas.pageID)
        onPageNeedsRecognition?(canvas.pageID)
    }

    func canvasWantsInkReload(_ canvas: PageCanvasView) {
        canvas.reloadInk()
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

    func toolbar(_ toolbar: EditorToolbar, requestsFavoritesEditorFrom anchor: UIView) {
        let host = UIHostingController(rootView: FavoritesEditorView(favorites: toolState.favorites) { [weak self] favorites in
            guard let self else { return }
            var state = self.toolState
            state.favorites = Array(favorites.prefix(EditorToolState.maxFavorites))
            if let active = state.activeFavoriteID, !state.favorites.contains(where: { $0.id == active }) {
                state.activeFavoriteID = nil
            }
            self.toolState = state
        })
        host.modalPresentationStyle = .popover
        host.preferredContentSize = CGSize(width: 400, height: 520)
        host.popoverPresentationController?.sourceView = anchor
        host.popoverPresentationController?.sourceRect = anchor.bounds
        host.popoverPresentationController?.delegate = self
        present(host, animated: true)
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
        onScrollDirectionChange?(isHorizontalPaging)
    }

    func toolbarDidRequestClearPage(_ toolbar: EditorToolbar) {
        guard let pageID = currentPageID else { return }
        let alert = UIAlertController(title: "Clear This Page?",
                                      message: "Everything written or placed on the page is removed. You can undo this.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear Page", style: .destructive) { [weak self] _ in
            self?.clearPage(pageID)
        })
        present(alert, animated: true)
    }

    /// Empties a page. Separate from the confirmation so the behaviour can be
    /// exercised without driving an alert.
    func clearPage(_ pageID: PageID) {
        selectionController.clearSelection()
        // Commit what is on the canvas *before* clearing it, so undo puts back
        // the stroke that was just drawn and not the older ink the document
        // happened to be holding.
        if let canvas = canvas(for: pageID) { commitInkImmediately(canvas: canvas) }
        performDocumentOperation("Clear Page") {
            try session.apply(.clearPage(pageID))
        }
        // The document is the authority again; reload the canvas from it.
        if let canvas = canvas(for: pageID), let page = session.editor.page(pageID) {
            canvas.setDrawing(PKDrawing(), assetID: page.inkLayers.first?.dataAssetID)
        }
        thumbnails.invalidate(pageID: pageID)
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
        // Finish anything still in a view first: a page is about to be removed,
        // and a queued commit for it would otherwise resolve against nothing.
        endActiveEditing()
        performDocumentOperation("Delete Page") {
            try session.apply(.deletePage(id))
        }
        forgetInkState(for: id)
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


// MARK: - System undo bridge

/// The object the responder-chain `UndoManager` registers its single bridging
/// action against. Keeping it separate from the view controller is what lets
/// `removeAllActions(withTarget:)` clear the bridge without touching a text
/// view's own undo registrations on the same manager.
@MainActor
final class EditorHistoryBridge: NSObject {
    weak var controller: NotebookEditorViewController?
    func undo() { controller?.performUndo() }
    func redo() { controller?.performRedo() }
}
