import Foundation
import DocumentCore

// Implementation of `DocumentEditor` (see EditingAPI.swift for the contract).
//
// Every command runs against a *copy* of the snapshot; if validation throws
// the editor is untouched. A successful command yields a `CommandEffect`
// describing which pages had their content changed, which pages entered or
// left `snapshot.pages`, and whether manifest-level document state changed.
// From that the editor derives the `ChangeSet` and the `UndoRecord`.

// MARK: - Command names

extension EditCommand {
    /// Default undo action name used when `apply` is called without a name.
    public var actionName: String {
        switch self {
        case .insertPage: return "Insert Page"
        case .insertPages: return "Insert Pages"
        case .deletePage: return "Delete Page"
        case .restorePage: return "Restore Page"
        case .duplicatePage: return "Duplicate Page"
        case .movePage: return "Move Page"
        case .setPageBookmark: return "Bookmark"
        case .setPageBackground: return "Change Paper"
        case .clearPage: return "Clear Page"
        case .addObject, .addObjects: return "Add"
        case .removeObjects: return "Delete"
        case .updateObject: return "Edit"
        case .transformObjects: return "Move"
        case .setObjectsLocked(_, _, let locked): return locked ? "Lock" : "Unlock"
        case .reorderObject, .bringToFront, .sendToBack: return "Reorder"
        case .setTapeRevealed(_, _, let revealed): return revealed ? "Reveal" : "Hide"
        case .replaceInk: return "Ink"
        case .setInkLayerVisible: return "Ink Visibility"
        case .setProblem: return "Problem Details"
        case .setProblemStatus: return "Problem Status"
        case .addReviewItem: return "Add to Review"
        case .updateReviewItem: return "Edit Review Item"
        case .removeReviewItem: return "Remove from Review"
        case .markReviewed: return "Mark Reviewed"
        case .reopenReview: return "Reopen Review"
        case .setTitle: return "Rename"
        case .setCover: return "Cover"
        case .setDefaultTemplate: return "Default Paper"
        case .setFavorite: return "Favorite"
        }
    }
}

/// What a command did to the working copy.
struct CommandEffect {
    /// Pages whose content changed; their `modifiedAt` is bumped.
    var contentPages: Set<PageID> = []
    /// Pages that entered or left `snapshot.pages` (insert/restore/delete); timestamps untouched.
    var membershipPages: Set<PageID> = []
    /// Manifest-level state (other than `document.modifiedAt`) changed.
    var documentChanged = false
}

extension DocumentEditor {

    // MARK: Apply

    func _apply(_ command: EditCommand, name: String?) throws -> ChangeSet {
        let now = clock.now()
        var working = snapshot
        let effect = try DocumentEditor.execute(command, on: &working, now: now)
        for id in effect.contentPages { working.pages[id]?.modifiedAt = now }
        working.document.modifiedAt = now

        let affected = effect.contentPages.union(effect.membershipPages)
        var before: [PageID: Page?] = [:]
        var after: [PageID: Page?] = [:]
        for id in affected {
            before.updateValue(snapshot.pages[id], forKey: id)
            after.updateValue(working.pages[id], forKey: id)
        }
        let changes = ChangeSet(changedPageIDs: affected, documentChanged: effect.documentChanged)
        let record = UndoRecord(name: name ?? command.actionName,
                                beforeDocument: snapshot.document, afterDocument: working.document,
                                beforePages: before, afterPages: after, changeSet: changes)
        setSnapshot(working)
        setRedoStack([])
        if var group = groupState {
            group.records.append(record)
            groupState = group
        } else {
            push(record)
        }
        mergePending(changes)
        return changes
    }

    private func push(_ record: UndoRecord) {
        var stack = undoStack
        stack.append(record)
        let limit = max(0, undoLimit)
        if stack.count > limit { stack.removeFirst(stack.count - limit) }
        setUndoStack(stack)
    }

    private func mergePending(_ changes: ChangeSet) {
        var pending = pendingChanges
        pending.merge(changes)
        setPendingChanges(pending)
    }

    // MARK: Groups

    func _beginGroup(name: String) {
        if groupState == nil { groupState = (name: name, records: []) }
        groupDepth += 1
    }

    func _endGroup() {
        guard groupDepth > 0 else { return }
        groupDepth -= 1
        guard groupDepth == 0, let group = groupState else { return }
        groupState = nil
        guard let first = group.records.first, let last = group.records.last else { return }
        var before: [PageID: Page?] = [:]
        var after: [PageID: Page?] = [:]
        var changes = ChangeSet.empty
        for record in group.records {
            for (id, page) in record.beforePages where before.index(forKey: id) == nil { before.updateValue(page, forKey: id) }
            for (id, page) in record.afterPages { after.updateValue(page, forKey: id) }
            changes.merge(record.changeSet)
        }
        push(UndoRecord(name: group.name, beforeDocument: first.beforeDocument, afterDocument: last.afterDocument,
                        beforePages: before, afterPages: after, changeSet: changes))
    }

    /// Closes an open group (whatever its depth) so undo never splits a partially recorded group.
    private func closeOpenGroup() {
        guard groupDepth > 0 else { return }
        groupDepth = 1
        _endGroup()
    }

    // MARK: Undo / redo

    func _undo() -> ChangeSet? {
        closeOpenGroup()
        var stack = undoStack
        guard let record = stack.popLast() else { return nil }
        setUndoStack(stack)
        restore(document: record.beforeDocument, pages: record.beforePages)
        setRedoStack(redoStack + [record])
        mergePending(record.changeSet)
        return record.changeSet
    }

    func _redo() -> ChangeSet? {
        closeOpenGroup()
        var stack = redoStack
        guard let record = stack.popLast() else { return nil }
        setRedoStack(stack)
        restore(document: record.afterDocument, pages: record.afterPages)
        setUndoStack(undoStack + [record])
        mergePending(record.changeSet)
        return record.changeSet
    }

    private func restore(document: Document, pages: [PageID: Page?]) {
        var working = snapshot
        working.document = document
        for (id, page) in pages {
            if let page = page { working.pages[id] = page } else { working.pages.removeValue(forKey: id) }
        }
        setSnapshot(working)
    }

    // MARK: Non-undoable state

    func _registerPendingAsset(_ asset: PendingAsset) {
        var working = snapshot
        working.assets[asset.asset.id] = asset.asset
        setSnapshot(working)
        mergePending(ChangeSet(newAssets: [asset]))
    }

    func _setLastViewedPageIndex(_ index: Int) {
        var working = snapshot
        let count = working.document.pageIDs.count
        working.document.lastViewedPageIndex = count == 0 ? 0 : min(max(0, index), count - 1)
        setSnapshot(working)
        mergePending(ChangeSet(documentChanged: true))
    }

    func _reset(to snapshot: DocumentSnapshot) {
        groupState = nil
        groupDepth = 0
        setUndoStack([])
        setRedoStack([])
        setPendingChanges(.empty)
        setSnapshot(snapshot)
    }

    // MARK: Command builders

    func _makeDuplicate(of pageID: PageID) -> Page? {
        guard let page = snapshot.pages[pageID] else { return nil }
        return DocumentEditor.reidentified(page, revisionID: snapshot.document.revisionHead, now: clock.now())
    }

    func _makeNewPage(template: PaperTemplate?, size: PageSize?) -> Page {
        let now = clock.now()
        return Page(size: size ?? snapshot.document.defaultPageSize,
                    background: .template(template ?? snapshot.document.defaultTemplate),
                    revisionID: snapshot.document.revisionHead, createdAt: now, modifiedAt: now)
    }

    func _copiesOfPages(_ ids: [PageID]) -> [Page] {
        let now = clock.now()
        return ids.compactMap { id in
            snapshot.pages[id].map { DocumentEditor.reidentified($0, revisionID: snapshot.document.revisionHead, now: now) }
        }
    }

    /// A copy of `page` with fresh page, object and ink-layer IDs. Asset references
    /// (background, images, ink blobs) are kept: assets are immutable and shareable.
    static func reidentified(_ page: Page, revisionID: RevisionID, now: Date) -> Page {
        var copy = page
        copy.id = PageID()
        copy.objects = page.objects.map { object in
            var o = object
            o.id = ObjectID()
            return o
        }
        copy.inkLayers = page.inkLayers.map { layer in
            var l = layer
            l.id = InkLayerID()
            return l
        }
        copy.revisionID = revisionID
        copy.createdAt = now
        copy.modifiedAt = now
        return copy
    }

    // MARK: Transform rule

    /// Applies a page-space transform to an object.
    ///
    /// - A **pure rotation** (orthonormal linear part with positive determinant and a
    ///   non-zero angle, optionally combined with translation, e.g. `rotation(radians:about:)`)
    ///   keeps the frame size, moves the frame center to `transform.apply(center)` and adds the
    ///   angle to `rotation`. A selection rotated about a common pivot therefore keeps every
    ///   member's shape.
    /// - **Any other transform** (translation, uniform or non-uniform scale, shear, reflection,
    ///   rotation combined with scale) replaces the frame with the axis-aligned bounding box of
    ///   the four transformed frame corners and leaves `rotation` unchanged. For a translation
    ///   this is exact; for a scale about a pivot the frame scales as expected and a rotated
    ///   object keeps its rotation.
    public static func transformed(_ object: CanvasObject, by transform: PageTransform) -> CanvasObject {
        var result = object
        if let angle = pureRotationAngle(of: transform) {
            let center = transform.apply(object.frame.center)
            let w = object.frame.width, h = object.frame.height
            result.frame = PageRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
            result.rotation = object.rotation + angle
        } else {
            result.frame = object.frame.applying(transform)
        }
        return result
    }

    /// The rotation angle when the linear part of `transform` is a pure rotation by a
    /// non-zero angle; nil for identity, translation, scale or any general transform.
    static func pureRotationAngle(of t: PageTransform, tolerance: Double = 1e-9) -> Double? {
        guard abs(t.a - t.d) <= tolerance, abs(t.b + t.c) <= tolerance,
              abs(t.a * t.a + t.b * t.b - 1) <= tolerance else { return nil }
        let angle = atan2(t.b, t.a)
        return abs(angle) <= tolerance ? nil : angle
    }

    // MARK: Execution

    static func execute(_ command: EditCommand, on s: inout DocumentSnapshot, now: Date) throws -> CommandEffect {
        var effect = CommandEffect()
        switch command {

        // MARK: Pages
        case .insertPage(let page, let index):
            try insert(pages: [page], at: index, into: &s, effect: &effect)

        case .insertPages(let pages, let index):
            try insert(pages: pages, at: index, into: &s, effect: &effect)

        case .deletePage(let id):
            guard let index = s.document.pageIDs.firstIndex(of: id), let page = s.pages[id] else { throw EditingError.pageNotFound(id) }
            guard s.document.pageIDs.count > 1 else { throw EditingError.cannotDeleteLastPage }
            s.document.pageIDs.remove(at: index)
            s.pages.removeValue(forKey: id)
            s.document.deletedPages.append(DeletedPage(page: page, originalIndex: index, deletedAt: now))
            clampLastViewedIndex(&s)
            effect.membershipPages.insert(id)
            effect.documentChanged = true

        case .restorePage(let id):
            guard let trashIndex = s.document.deletedPages.firstIndex(where: { $0.id == id }) else { throw EditingError.deletedPageNotFound(id) }
            let deleted = s.document.deletedPages.remove(at: trashIndex)
            let index = min(max(0, deleted.originalIndex), s.document.pageIDs.count)
            s.document.pageIDs.insert(id, at: index)
            s.pages[id] = deleted.page
            effect.membershipPages.insert(id)
            effect.documentChanged = true

        case .duplicatePage(let source, let copy, let index):
            guard s.document.pageIDs.contains(source), s.pages[source] != nil else { throw EditingError.pageNotFound(source) }
            try insert(pages: [copy], at: index, into: &s, effect: &effect)

        case .movePage(let id, let index):
            guard let from = s.document.pageIDs.firstIndex(of: id) else { throw EditingError.pageNotFound(id) }
            guard index >= 0, index < s.document.pageIDs.count else { throw EditingError.invalidIndex(index) }
            s.document.pageIDs.remove(at: from)
            s.document.pageIDs.insert(id, at: index)
            effect.documentChanged = true

        case .setPageBookmark(let id, let flag):
            try mutatePage(id, in: &s, effect: &effect) { $0.isBookmarked = flag }

        case .setPageBackground(let id, let background, let size):
            try mutatePage(id, in: &s, effect: &effect) { $0.background = background; $0.size = size }

        case .clearPage(let id):
            try mutatePage(id, in: &s, effect: &effect) { page in
                page.objects.removeAll()
                for i in page.inkLayers.indices { page.inkLayers[i].dataAssetID = nil }
            }

        // MARK: Objects
        case .addObject(let pageID, let object, let index):
            try mutatePage(pageID, in: &s, effect: &effect) { page in
                guard page.object(object.id) == nil else { throw EditingError.duplicateID(object.id.description) }
                let at = index ?? page.objects.count
                guard at >= 0, at <= page.objects.count else { throw EditingError.invalidIndex(at) }
                page.objects.insert(object, at: at)
            }

        case .addObjects(let pageID, let objects):
            try mutatePage(pageID, in: &s, effect: &effect) { page in
                var seen = Set(page.objects.map(\.id))
                for object in objects {
                    guard seen.insert(object.id).inserted else { throw EditingError.duplicateID(object.id.description) }
                }
                page.objects.append(contentsOf: objects)
            }

        case .removeObjects(let pageID, let ids):
            try mutatePage(pageID, in: &s, effect: &effect) { page in
                let indices = try indices(of: ids, in: page, rejectLocked: true)
                let removing = Set(indices)
                page.objects = page.objects.enumerated().filter { !removing.contains($0.offset) }.map(\.element)
            }

        case .updateObject(let pageID, let object):
            try mutatePage(pageID, in: &s, effect: &effect) { page in
                let index = try indices(of: [object.id], in: page, rejectLocked: true)[0]
                page.objects[index] = object
            }

        case .transformObjects(let pageID, let ids, let transform):
            try mutatePage(pageID, in: &s, effect: &effect) { page in
                for index in try indices(of: ids, in: page, rejectLocked: true) {
                    page.objects[index] = transformed(page.objects[index], by: transform)
                }
            }

        case .setObjectsLocked(let pageID, let ids, let locked):
            try mutatePage(pageID, in: &s, effect: &effect) { page in
                for index in try indices(of: ids, in: page, rejectLocked: false) { page.objects[index].isLocked = locked }
            }

        case .reorderObject(let pageID, let id, let index):
            try mutatePage(pageID, in: &s, effect: &effect) { page in
                let from = try indices(of: [id], in: page, rejectLocked: false)[0]
                guard index >= 0, index < page.objects.count else { throw EditingError.invalidIndex(index) }
                let object = page.objects.remove(at: from)
                page.objects.insert(object, at: index)
            }

        case .bringToFront(let pageID, let ids):
            try mutatePage(pageID, in: &s, effect: &effect) { page in
                let moving = Set(try indices(of: ids, in: page, rejectLocked: false))
                let (kept, lifted) = partition(page.objects, moving: moving)
                page.objects = kept + lifted
            }

        case .sendToBack(let pageID, let ids):
            try mutatePage(pageID, in: &s, effect: &effect) { page in
                let moving = Set(try indices(of: ids, in: page, rejectLocked: false))
                let (kept, lowered) = partition(page.objects, moving: moving)
                page.objects = lowered + kept
            }

        case .setTapeRevealed(let pageID, let id, let revealed):
            var changed = false
            try mutatePage(pageID, in: &s, effect: &effect) { page in
                let index = try indices(of: [id], in: page, rejectLocked: false)[0]
                guard case .tape(var tape) = page.objects[index].content else {
                    throw EditingError.objectKindMismatch(id, expected: .tape)
                }
                changed = tape.isRevealed != revealed
                tape.isRevealed = revealed
                page.objects[index].content = .tape(tape)
            }
            if changed {
                for i in s.document.reviewItems.indices where s.document.reviewItems[i].answerTapeID == id {
                    s.document.reviewItems[i] = ReviewRules.recordingReveal(s.document.reviewItems[i], revealed: revealed, at: now)
                    effect.documentChanged = true
                }
            }

        // MARK: Ink
        case .replaceInk(let pageID, let layerID, let assetID):
            try mutatePage(pageID, in: &s, effect: &effect) { page in
                guard let index = page.inkLayers.firstIndex(where: { $0.id == layerID }) else { throw EditingError.inkLayerNotFound(layerID) }
                page.inkLayers[index].dataAssetID = assetID
            }

        case .setInkLayerVisible(let pageID, let layerID, let visible):
            try mutatePage(pageID, in: &s, effect: &effect) { page in
                guard let index = page.inkLayers.firstIndex(where: { $0.id == layerID }) else { throw EditingError.inkLayerNotFound(layerID) }
                page.inkLayers[index].isVisible = visible
            }

        // MARK: Problem Pages and review
        case .setProblem(let pageID, let metadata):
            try mutatePage(pageID, in: &s, effect: &effect) { $0.problem = metadata }

        case .setProblemStatus(let pageID, let status):
            try mutatePage(pageID, in: &s, effect: &effect) { page in
                guard page.problem != nil else { throw EditingError.notAProblemPage(pageID) }
                page.problem?.status = status
            }

        case .addReviewItem(let item):
            guard s.document.pageIDs.contains(item.pageID) || s.document.deletedPages.contains(where: { $0.id == item.pageID }) else {
                throw EditingError.pageNotFound(item.pageID)
            }
            guard !s.document.reviewItems.contains(where: { $0.id == item.id }) else { throw EditingError.duplicateID(item.id.description) }
            s.document.reviewItems.append(item)
            effect.documentChanged = true

        case .updateReviewItem(let item):
            let index = try reviewIndex(item.id, in: s)
            s.document.reviewItems[index] = item
            effect.documentChanged = true

        case .removeReviewItem(let id):
            let index = try reviewIndex(id, in: s)
            s.document.reviewItems.remove(at: index)
            effect.documentChanged = true

        case .markReviewed(let id, let at):
            let index = try reviewIndex(id, in: s)
            s.document.reviewItems[index] = ReviewRules.markingReviewed(s.document.reviewItems[index], at: at)
            effect.documentChanged = true

        case .reopenReview(let id, let at):
            let index = try reviewIndex(id, in: s)
            s.document.reviewItems[index] = ReviewRules.reopening(s.document.reviewItems[index], at: at)
            effect.documentChanged = true

        // MARK: Document metadata
        case .setTitle(let title):
            s.document.title = title
            effect.documentChanged = true
        case .setCover(let cover):
            s.document.cover = cover
            effect.documentChanged = true
        case .setDefaultTemplate(let template):
            s.document.defaultTemplate = template
            effect.documentChanged = true
        case .setFavorite(let flag):
            s.document.isFavorite = flag
            effect.documentChanged = true
        }
        return effect
    }

    // MARK: Helpers

    private static func insert(pages: [Page], at index: Int, into s: inout DocumentSnapshot, effect: inout CommandEffect) throws {
        guard index >= 0, index <= s.document.pageIDs.count else { throw EditingError.invalidIndex(index) }
        var seen = Set<PageID>()
        for page in pages {
            guard s.pages[page.id] == nil, !s.document.pageIDs.contains(page.id),
                  !s.document.deletedPages.contains(where: { $0.id == page.id }), seen.insert(page.id).inserted else {
                throw EditingError.duplicateID(page.id.description)
            }
        }
        s.document.pageIDs.insert(contentsOf: pages.map(\.id), at: index)
        for page in pages {
            s.pages[page.id] = page
            effect.membershipPages.insert(page.id)
        }
        effect.documentChanged = true
    }

    private static func mutatePage(_ id: PageID, in s: inout DocumentSnapshot, effect: inout CommandEffect,
                                   _ body: (inout Page) throws -> Void) throws {
        guard s.document.pageIDs.contains(id), var page = s.pages[id] else { throw EditingError.pageNotFound(id) }
        try body(&page)
        s.pages[id] = page
        effect.contentPages.insert(id)
    }

    /// Indices of `ids` in `page.objects`, in the order given. Throws for unknown IDs
    /// and, when `rejectLocked`, for locked objects.
    private static func indices(of ids: [ObjectID], in page: Page, rejectLocked: Bool) throws -> [Int] {
        try ids.map { id in
            guard let index = page.objectIndex(id) else { throw EditingError.objectNotFound(id) }
            if rejectLocked, page.objects[index].isLocked { throw EditingError.objectLocked(id) }
            return index
        }
    }

    private static func partition(_ objects: [CanvasObject], moving: Set<Int>) -> (kept: [CanvasObject], moved: [CanvasObject]) {
        var kept: [CanvasObject] = [], moved: [CanvasObject] = []
        for (i, o) in objects.enumerated() { if moving.contains(i) { moved.append(o) } else { kept.append(o) } }
        return (kept, moved)
    }

    private static func reviewIndex(_ id: ReviewItemID, in s: DocumentSnapshot) throws -> Int {
        guard let index = s.document.reviewItems.firstIndex(where: { $0.id == id }) else { throw EditingError.reviewItemNotFound(id) }
        return index
    }

    private static func clampLastViewedIndex(_ s: inout DocumentSnapshot) {
        let count = s.document.pageIDs.count
        if count > 0, s.document.lastViewedPageIndex >= count { s.document.lastViewedPageIndex = count - 1 }
    }
}

// MARK: - Commit feedback (used by the Workspace session)

extension DocumentEditor {
    /// Adopts the revision identifiers Persistence assigned when a commit
    /// succeeded: the new `revisionHead`, the revision table, and the revision
    /// of every page the commit wrote. Undo history and pending changes are
    /// untouched, so a page edited while the commit was in flight is still
    /// pending and is rewritten (under a newer revision) by the next commit.
    /// Without this feedback every later commit would rewrite every page,
    /// because the page records would keep naming a revision the manifest no
    /// longer lists.
    public func adoptCommittedRevisions(from committed: DocumentSnapshot, pagesWritten: [PageID]) {
        var working = snapshot
        working.document.revisionHead = committed.document.revisionHead
        working.document.schemaVersion = committed.document.schemaVersion
        for id in pagesWritten {
            guard working.pages[id] != nil, let revisionID = committed.pages[id]?.revisionID else { continue }
            working.pages[id]!.revisionID = revisionID
        }
        working.revisions = committed.revisions
        setSnapshot(working)
    }

    /// Non-undoable library filing change (folder membership is a library
    /// operation, not an edit); marks the document changed so the next commit
    /// persists it. Needed while the document is open, because a commit writes
    /// the whole `Document` value and would otherwise undo a move made on disk.
    public func setFolderID(_ folderID: FolderID?) {
        var working = snapshot
        working.document.folderID = folderID
        setSnapshot(working)
        mergePending(ChangeSet(documentChanged: true))
    }
}
