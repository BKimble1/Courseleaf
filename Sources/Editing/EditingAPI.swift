import Foundation
import DocumentCore

// Public contract of the Editing module. `DocumentEditor` owns a
// `DocumentSnapshot` and applies invertible `EditCommand`s with grouped undo.
// Implementation lives in DocumentEditor.swift / Selection.swift / ReviewRules.swift.
//
// Undo model: before applying a command the editor captures the affected
// pieces of state (the touched pages' values and the `Document` value), applies
// the command, captures the after-state, and pushes an `UndoRecord`. Undo/redo
// restore the captured values and emit the same `ChangeSet`. Grouped commands
// (`beginGroup`/`endGroup` or `performGrouped`) form one record, so a lasso
// move of ink + text + image + shape undoes in one step (A09).

public enum EditingError: Error, Equatable {
    case pageNotFound(PageID)
    case objectNotFound(ObjectID)
    case inkLayerNotFound(InkLayerID)
    case reviewItemNotFound(ReviewItemID)
    case objectLocked(ObjectID)
    case invalidIndex(Int)
    case deletedPageNotFound(PageID)
    case cannotDeleteLastPage
    /// An inserted page, object or review item reuses an ID that already exists in the document.
    case duplicateID(String)
    /// The command needs an object of another kind (e.g. `setTapeRevealed` on a text object).
    case objectKindMismatch(ObjectID, expected: ObjectKind)
    /// `setProblemStatus` on a page that has no `ProblemMetadata`.
    case notAProblemPage(PageID)
    case notImplemented(String)
}

public enum EditCommand: Hashable, Sendable {
    // Pages (indices refer to `document.pageIDs`)
    case insertPage(Page, at: Int)
    case insertPages([Page], at: Int)
    /// Moves the page into `document.deletedPages` (recoverable) and removes it from
    /// `snapshot.pages`. Refuses to delete the last page. The page ID is listed in the
    /// change set although the page is no longer in `pages`: a changed page ID that
    /// is absent from `pages` means "deleted; its record is in `document.deletedPages`".
    case deletePage(PageID)
    /// Puts a deleted page back at `min(originalIndex, pageCount)`. Its review items become visible again.
    case restorePage(PageID)
    /// `copy` must already carry fresh page/object IDs (see `DocumentEditor.makeDuplicate`).
    case duplicatePage(source: PageID, copy: Page, at: Int)
    case movePage(PageID, to: Int)
    case setPageBookmark(PageID, Bool)
    case setPageBackground(PageID, PageBackground, size: PageSize)
    /// Removes every object and empties every ink layer (ink assets become nil) but keeps the page and its metadata.
    case clearPage(PageID)

    // Objects
    /// nil index appends at the end of the page's object array (top of the array's z-order).
    /// Bands are a rendering concept: the renderer draws image objects beneath ink and
    /// text/shape/tape above it regardless of array position, so the editor keeps one
    /// array per page and ordering commands operate on that single array.
    case addObject(PageID, CanvasObject, at: Int?)
    case addObjects(PageID, [CanvasObject])
    case removeObjects(PageID, [ObjectID])
    /// Replaces an object wholesale (content, frame, rotation, lock) by ID.
    case updateObject(PageID, CanvasObject)
    /// Applies a page-space transform to each object (see `DocumentEditor.transformed(_:by:)`):
    /// a pure rotation moves the frame center along the transform and adds the angle to
    /// `rotation`; any other transform (translation, scale, general) replaces the frame with
    /// the axis-aligned bounding box of the transformed frame corners and keeps `rotation`.
    /// Locked objects are rejected with `objectLocked`.
    case transformObjects(PageID, [ObjectID], PageTransform)
    case setObjectsLocked(PageID, [ObjectID], Bool)
    /// Moves an object to `index` in the page's object array (0 = back-most).
    case reorderObject(PageID, ObjectID, to: Int)
    /// Moves the objects (keeping their relative order) to the end of the page's object array.
    case bringToFront(PageID, [ObjectID])
    /// Moves the objects (keeping their relative order) to the start of the page's object array.
    case sendToBack(PageID, [ObjectID])
    /// Sets the tape's revealed state (allowed on locked tape) and records a `revealed`/`hidden`
    /// event on every review item whose `answerTapeID` is this object when the state changes.
    case setTapeRevealed(PageID, ObjectID, Bool)

    // Ink (blob assets; the editor never inspects ink bytes). Register the blob with
    // `registerPendingAsset` first; the editor does not check that the asset exists.
    case replaceInk(PageID, InkLayerID, dataAssetID: AssetID?)
    case setInkLayerVisible(PageID, InkLayerID, Bool)

    // Problem Pages and review
    case setProblem(PageID, ProblemMetadata?)
    case setProblemStatus(PageID, ProblemStatus)
    case addReviewItem(ReviewItem)
    case updateReviewItem(ReviewItem)
    case removeReviewItem(ReviewItemID)
    /// Applies `ReviewRules.markingReviewed`: state `reviewed`, `lastReviewedAt`, `markedReviewed` event.
    case markReviewed(ReviewItemID, at: Date)
    /// Applies `ReviewRules.reopening`: state `pending` plus a `reopened` event (no-op when already pending).
    case reopenReview(ReviewItemID, at: Date)

    // Document metadata
    case setTitle(String)
    case setCover(CoverStyle)
    case setDefaultTemplate(PaperTemplate)
    case setFavorite(Bool)
}

/// A page-scoped selection of objects and ink strokes (by stroke index per layer).
public struct Selection: Hashable, Sendable {
    public var pageID: PageID
    public var objectIDs: Set<ObjectID>
    public var strokeIndices: [InkLayerID: [Int]]
    public init(pageID: PageID, objectIDs: Set<ObjectID> = [], strokeIndices: [InkLayerID: [Int]] = [:]) {
        self.pageID = pageID; self.objectIDs = objectIDs; self.strokeIndices = strokeIndices
    }
    public var isEmpty: Bool { objectIDs.isEmpty && strokeIndices.values.allSatisfy(\.isEmpty) }
    public var hasInk: Bool { strokeIndices.values.contains { !$0.isEmpty } }
}

/// Content types a lasso may pick up; the student can filter.
public struct SelectionFilter: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let ink = SelectionFilter(rawValue: 1 << 0)
    public static let text = SelectionFilter(rawValue: 1 << 1)
    public static let images = SelectionFilter(rawValue: 1 << 2)
    public static let shapes = SelectionFilter(rawValue: 1 << 3)
    public static let tape = SelectionFilter(rawValue: 1 << 4)
    public static let all: SelectionFilter = [.ink, .text, .images, .shapes, .tape]
}

/// Actions the UI may offer. `SelectionRules.availableActions` returns only the
/// actions valid for *every* member of the selection; the UI hides the rest.
public enum SelectionAction: String, Hashable, Sendable, CaseIterable {
    case move, resize, rotate, copy, cut, paste, duplicate, delete, recolor, lock, unlock,
         bringToFront, sendToBack, editText, cropImage, revealTape, hideTape, addToReview
}

public struct UndoRecord: Hashable, Sendable {
    public var name: String
    public var beforeDocument: Document
    public var afterDocument: Document
    public var beforePages: [PageID: Page?]
    public var afterPages: [PageID: Page?]
    public var changeSet: ChangeSet
    public init(name: String, beforeDocument: Document, afterDocument: Document, beforePages: [PageID: Page?], afterPages: [PageID: Page?], changeSet: ChangeSet) {
        self.name = name; self.beforeDocument = beforeDocument; self.afterDocument = afterDocument
        self.beforePages = beforePages; self.afterPages = afterPages; self.changeSet = changeSet
    }
}

/// Owns an in-memory document and applies commands with undo. Not thread-safe:
/// one owner (the main-actor `DocumentSession`) drives it.
///
/// Timestamps: a command that changes a page's content (objects, ink, background,
/// bookmark, problem metadata, clear) sets that page's `modifiedAt`; every command
/// sets `document.modifiedAt`. Structural page commands (insert, delete, restore,
/// move, duplicate) leave the moved page's own timestamps alone. Nothing else
/// (revision IDs, `createdAt`) is bumped; Persistence assigns revisions on commit.
///
/// Change sets: `changedPageIDs` lists every page whose entry in `snapshot.pages`
/// changed, including pages that were inserted, restored or deleted (a listed ID that
/// is absent from `pages` was deleted and now lives in `document.deletedPages`).
/// `documentChanged` is true only when manifest-level state other than
/// `document.modifiedAt` changed (page order, trash, review items, metadata).
/// Registering an asset is not undoable; unreferenced assets are reclaimed by GC.
public final class DocumentEditor {
    public private(set) var snapshot: DocumentSnapshot
    public let clock: Clock
    public var undoLimit: Int = 200
    public private(set) var undoStack: [UndoRecord] = []
    public private(set) var redoStack: [UndoRecord] = []
    /// Changes since the last `takePendingChanges()`; the session turns these into commits.
    public private(set) var pendingChanges: ChangeSet = .empty
    private var openGroup: (name: String, records: [UndoRecord])?
    /// Nesting depth of `beginGroup` calls; only the outermost `endGroup` closes the record.
    var groupDepth: Int = 0

    public init(snapshot: DocumentSnapshot, clock: Clock = SystemClock()) {
        self.snapshot = snapshot
        self.clock = clock
    }

    public var document: Document { snapshot.document }
    public func page(_ id: PageID) -> Page? { snapshot.pages[id] }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoActionName: String? { undoStack.last?.name }
    public var redoActionName: String? { redoStack.last?.name }

    // MARK: Commands (implemented in DocumentEditor.swift)

    /// Applies one command (or adds it to the open group), records undo, and
    /// returns the resulting change set (also merged into `pendingChanges`).
    @discardableResult
    public func apply(_ command: EditCommand, name: String? = nil) throws -> ChangeSet {
        try _apply(command, name: name)
    }
    public func beginGroup(name: String) { _beginGroup(name: name) }
    public func endGroup() { _endGroup() }
    public func performGrouped<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        beginGroup(name: name)
        defer { endGroup() }
        return try body()
    }
    @discardableResult public func undo() -> ChangeSet? { _undo() }
    @discardableResult public func redo() -> ChangeSet? { _redo() }
    public func takePendingChanges() -> ChangeSet { let c = pendingChanges; pendingChanges = .empty; return c }
    /// Registers new asset bytes to be written with the next commit (image, ink blob).
    public func registerPendingAsset(_ asset: PendingAsset) { _registerPendingAsset(asset) }
    /// Non-undoable view state (last viewed page); marks the document changed.
    public func setLastViewedPageIndex(_ index: Int) { _setLastViewedPageIndex(index) }
    /// Replaces the snapshot after an external reload (e.g. recovery); clears undo.
    public func reset(to snapshot: DocumentSnapshot) { _reset(to: snapshot) }

    // MARK: Command builders

    /// A duplicate of the page with fresh page and object IDs and the same ink assets (immutable, shareable).
    public func makeDuplicate(of pageID: PageID) -> Page? { _makeDuplicate(of: pageID) }
    /// A new page using the document defaults, inserted after `index` (nil = end).
    public func makeNewPage(template: PaperTemplate? = nil, size: PageSize? = nil) -> Page { _makeNewPage(template: template, size: size) }
    /// Copies of the pages with fresh IDs for insertion into another document; assets referenced must be copied by the caller.
    public func copiesOfPages(_ ids: [PageID]) -> [Page] { _copiesOfPages(ids) }

    // The hooks `_apply`, `_beginGroup`, `_endGroup`, `_undo`, `_redo`, `_registerPendingAsset`,
    // `_setLastViewedPageIndex`, `_reset(to:)`, `_makeDuplicate(of:)`, `_makeNewPage(template:size:)`
    // and `_copiesOfPages(_:)` are implemented in DocumentEditor.swift.

    // Internal mutators used by the implementation file.
    func setSnapshot(_ s: DocumentSnapshot) { snapshot = s }
    func setUndoStack(_ s: [UndoRecord]) { undoStack = s }
    func setRedoStack(_ s: [UndoRecord]) { redoStack = s }
    func setPendingChanges(_ c: ChangeSet) { pendingChanges = c }
    var groupState: (name: String, records: [UndoRecord])? { get { openGroup } set { openGroup = newValue } }
}

/// Hit testing and action rules for selections (implemented in Selection.swift).
public enum SelectionRules {
    /// Objects (never locked ones) whose bounds intersect `rect`, filtered by content type.
    public static func objects(in page: Page, intersecting rect: PageRect, filter: SelectionFilter = .all) -> [ObjectID] {
        _objects(in: page, intersecting: rect, filter: filter)
    }
    /// Objects whose bounds lie inside the closed polygon.
    public static func objects(in page: Page, inside polygon: [PagePoint], filter: SelectionFilter = .all) -> [ObjectID] {
        _objects(in: page, inside: polygon, filter: filter)
    }
    /// The top-most unlocked object containing the point, if any.
    public static func object(in page: Page, at point: PagePoint) -> ObjectID? { _object(in: page, at: point) }
    /// Actions valid for every member of the selection.
    public static func availableActions(for selection: Selection, in page: Page) -> Set<SelectionAction> {
        _availableActions(for: selection, in: page)
    }
    /// Union of object bounds and the given ink bounds, in page space.
    public static func bounds(of selection: Selection, in page: Page, inkBounds: PageRect?) -> PageRect? {
        _bounds(of: selection, in: page, inkBounds: inkBounds)
    }

    // `_objects(in:intersecting:filter:)`, `_objects(in:inside:filter:)`, `_object(in:at:)`,
    // `_availableActions(for:in:)` and `_bounds(of:in:inkBounds:)` are implemented in Selection.swift.
}
