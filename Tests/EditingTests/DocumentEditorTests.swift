import XCTest
import DocumentCore
@testable import Editing

final class DocumentEditorTests: XCTestCase {

    // MARK: A09 – grouped undo

    func testA09GroupedMoveOfObjectsAndInkUndoesInOneStepAndRedoReapplies() throws {
        let clock = ManualClock(start: EditingFixture.start)
        var snap = EditingFixture.snapshot(pageCount: 2)
        let pageID = snap.document.pageIDs[0]
        let otherID = snap.document.pageIDs[1]
        let picture = EditingFixture.imageAsset(1)
        snap.assets[picture.asset.id] = picture.asset
        let image = EditingFixture.image(picture.asset.id, frame: PageRect(x: 50, y: 300, width: 200, height: 150))
        let text = EditingFixture.text("hello", frame: PageRect(x: 10, y: 10, width: 100, height: 20))
        let shape = EditingFixture.shape(frame: PageRect(x: 400, y: 400, width: 80, height: 80))
        snap.pages[pageID]!.objects = [image, text, shape]
        let ink1 = EditingFixture.inkAsset(1), ink2 = EditingFixture.inkAsset(2)
        snap.assets[ink1.asset.id] = ink1.asset
        snap.pages[pageID]!.inkLayers[0].dataAssetID = ink1.asset.id

        let editor = DocumentEditor(snapshot: snap, clock: clock)
        let layerID = editor.firstInkLayerID(of: pageID)
        editor.registerPendingAsset(ink2)   // the new stroke blob; registration is not an undo step
        _ = editor.takePendingChanges()
        XCTAssertFalse(editor.canUndo)
        let original = editor.snapshot
        XCTAssertEqual(original.assets[ink2.asset.id], ink2.asset)
        let originalOther = original.pages[otherID]!
        clock.advance(by: 7)

        let changes = try editor.performGrouped("Move Selection") { () throws -> ChangeSet in
            var c = try editor.apply(.transformObjects(pageID, [text.id, image.id, shape.id], .translation(x: 30, y: -12)))
            c.merge(try editor.apply(.replaceInk(pageID, layerID, dataAssetID: ink2.asset.id)))
            return c
        }
        XCTAssertEqual(changes, ChangeSet(changedPageIDs: [pageID]))
        XCTAssertEqual(editor.undoStack.count, 1, "the whole group is one undo record")
        XCTAssertEqual(editor.undoActionName, "Move Selection")
        XCTAssertFalse(editor.canRedo)

        let moved = editor.snapshot
        XCTAssertNotEqual(moved, original)
        let page = editor.page(pageID)!
        XCTAssertEqual(page.object(text.id)!.frame, PageRect(x: 40, y: -2, width: 100, height: 20))
        XCTAssertEqual(page.object(image.id)!.frame, PageRect(x: 80, y: 288, width: 200, height: 150))
        XCTAssertEqual(page.object(shape.id)!.frame, PageRect(x: 430, y: 388, width: 80, height: 80))
        XCTAssertEqual(page.inkLayers[0].dataAssetID, ink2.asset.id)
        XCTAssertEqual(page.modifiedAt, EditingFixture.start.addingTimeInterval(7))
        XCTAssertEqual(editor.document.modifiedAt, EditingFixture.start.addingTimeInterval(7))
        XCTAssertEqual(editor.page(otherID), originalOther, "untouched page keeps its value")
        XCTAssertEqual(editor.takePendingChanges(), ChangeSet(changedPageIDs: [pageID]))

        let undone = editor.undo()
        XCTAssertEqual(undone, ChangeSet(changedPageIDs: [pageID]))
        XCTAssertEqual(editor.snapshot, original, "one undo restores the exact original snapshot")
        XCTAssertFalse(editor.canUndo)
        XCTAssertTrue(editor.canRedo)
        XCTAssertEqual(editor.redoActionName, "Move Selection")
        XCTAssertEqual(editor.pendingChanges, ChangeSet(changedPageIDs: [pageID]))

        let redone = editor.redo()
        XCTAssertEqual(redone, ChangeSet(changedPageIDs: [pageID]))
        XCTAssertEqual(editor.snapshot, moved, "redo re-applies the group exactly")
        XCTAssertTrue(editor.canUndo)
        XCTAssertFalse(editor.canRedo)
    }

    func testNestedGroupsFormOneRecordAndFailedCommandLeavesSnapshotUntouched() throws {
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 2), clock: ManualClock())
        let pageID = editor.document.pageIDs[0]
        let original = editor.snapshot
        try editor.performGrouped("Outer") {
            try editor.apply(.setPageBookmark(pageID, true))
            try editor.performGrouped("Inner") {
                try editor.apply(.setTitle("Renamed"))
                XCTAssertThrowsEditingError(try editor.apply(.movePage(pageID, to: 9)), .invalidIndex(9))
            }
            try editor.apply(.setFavorite(true))
        }
        XCTAssertEqual(editor.undoStack.count, 1)
        XCTAssertEqual(editor.undoActionName, "Outer")
        XCTAssertEqual(editor.undoStack[0].changeSet, ChangeSet(changedPageIDs: [pageID], documentChanged: true))
        XCTAssertEqual(editor.document.title, "Renamed")
        XCTAssertTrue(editor.document.isFavorite)
        XCTAssertTrue(editor.page(pageID)!.isBookmarked)
        editor.undo()
        XCTAssertEqual(editor.snapshot, original)
    }

    // MARK: A11 – page operations keep every other page stable

    func testA11PageOperationsKeepOtherPagesAndIDsStable() throws {
        let clock = ManualClock(start: EditingFixture.start)
        var snap = EditingFixture.snapshot(pageCount: 5)
        let ids = snap.document.pageIDs
        for (i, id) in ids.enumerated() {
            snap.pages[id]!.objects = [EditingFixture.text("page \(i)", frame: PageRect(x: 10, y: 10 * Double(i + 1), width: 50, height: 10))]
            snap.pages[id]!.isBookmarked = i % 2 == 0
        }
        let editor = DocumentEditor(snapshot: snap, clock: clock)
        let original = editor.snapshot
        func assertOthersUntouched(except touched: Set<PageID>, _ label: String, line: UInt = #line) {
            for id in ids where !touched.contains(id) {
                XCTAssertEqual(editor.page(id), original.pages[id], "\(label): page \(id) changed", line: line)
            }
        }

        // insert
        clock.advance(by: 1)
        let fresh = editor.makeNewPage(template: .grid)
        var changes = try editor.apply(.insertPage(fresh, at: 1))
        XCTAssertEqual(changes, ChangeSet(changedPageIDs: [fresh.id], documentChanged: true))
        XCTAssertEqual(editor.document.pageIDs, [ids[0], fresh.id, ids[1], ids[2], ids[3], ids[4]])
        XCTAssertEqual(editor.page(fresh.id), fresh)
        assertOthersUntouched(except: [], "insert")

        // move
        changes = try editor.apply(.movePage(ids[4], to: 0))
        XCTAssertEqual(changes, ChangeSet(changedPageIDs: [], documentChanged: true))
        XCTAssertEqual(editor.document.pageIDs, [ids[4], ids[0], fresh.id, ids[1], ids[2], ids[3]])
        assertOthersUntouched(except: [], "move")

        // delete
        clock.advance(by: 1)
        changes = try editor.apply(.deletePage(ids[1]))
        XCTAssertEqual(changes, ChangeSet(changedPageIDs: [ids[1]], documentChanged: true))
        XCTAssertEqual(editor.document.pageIDs, [ids[4], ids[0], fresh.id, ids[2], ids[3]])
        XCTAssertNil(editor.page(ids[1]), "deleted page leaves snapshot.pages")
        XCTAssertEqual(editor.document.deletedPages.map(\.id), [ids[1]])
        XCTAssertEqual(editor.document.deletedPages[0].originalIndex, 3)
        XCTAssertEqual(editor.document.deletedPages[0].deletedAt, clock.now())
        XCTAssertEqual(editor.document.deletedPages[0].page, original.pages[ids[1]], "trash keeps the page value intact")
        assertOthersUntouched(except: [ids[1]], "delete")

        // restore (after another move so the original index is clamped/reused)
        try editor.apply(.movePage(fresh.id, to: 4))
        changes = try editor.apply(.restorePage(ids[1]))
        XCTAssertEqual(changes, ChangeSet(changedPageIDs: [ids[1]], documentChanged: true))
        XCTAssertEqual(editor.document.pageIDs, [ids[4], ids[0], ids[2], ids[1], ids[3], fresh.id])
        XCTAssertEqual(editor.page(ids[1]), original.pages[ids[1]], "restored page is identical, same ID")
        XCTAssertTrue(editor.document.deletedPages.isEmpty)
        assertOthersUntouched(except: [], "restore")

        // duplicate
        clock.advance(by: 1)
        let copy = editor.makeDuplicate(of: ids[2])!
        XCTAssertNotEqual(copy.id, ids[2])
        XCTAssertEqual(EditingFixture.PageContent(copy).objects.map(\.content), original.pages[ids[2]]!.objects.map(\.content))
        XCTAssertNotEqual(copy.objects[0].id, original.pages[ids[2]]!.objects[0].id, "duplicate objects get fresh IDs")
        XCTAssertNotEqual(copy.inkLayers[0].id, original.pages[ids[2]]!.inkLayers[0].id, "duplicate ink layers get fresh IDs")
        changes = try editor.apply(.duplicatePage(source: ids[2], copy: copy, at: 3))
        XCTAssertEqual(changes, ChangeSet(changedPageIDs: [copy.id], documentChanged: true))
        XCTAssertEqual(editor.document.pageIDs, [ids[4], ids[0], ids[2], copy.id, ids[1], ids[3], fresh.id])
        XCTAssertEqual(editor.page(copy.id), copy)
        assertOthersUntouched(except: [], "duplicate")

        // IDs remain stable: every original page still present with the same ID and content
        XCTAssertEqual(Set(editor.document.pageIDs).intersection(ids), Set(ids))
        XCTAssertTrue(editor.snapshot.validate().isEmpty, "\(editor.snapshot.validate())")

        // undo everything restores the original exactly
        while editor.canUndo { editor.undo() }
        XCTAssertEqual(editor.snapshot, original)
        while editor.canRedo { editor.redo() }
        XCTAssertEqual(editor.document.pageIDs, [ids[4], ids[0], ids[2], copy.id, ids[1], ids[3], fresh.id])
    }

    func testDeletingTheLastPageIsRefused() throws {
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 2), clock: ManualClock())
        let ids = editor.document.pageIDs
        try editor.apply(.deletePage(ids[0]))
        let before = editor.snapshot
        XCTAssertThrowsEditingError(try editor.apply(.deletePage(ids[1])), .cannotDeleteLastPage)
        XCTAssertEqual(editor.snapshot, before)
        XCTAssertEqual(editor.undoStack.count, 1)
        XCTAssertThrowsEditingError(try editor.apply(.deletePage(ids[0])), .pageNotFound(ids[0]))
    }

    func testRestoreUsesMinOfOriginalIndexAndPageCountAndClampsLastViewed() throws {
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 3), clock: ManualClock())
        let ids = editor.document.pageIDs
        editor.setLastViewedPageIndex(2)
        XCTAssertEqual(editor.document.lastViewedPageIndex, 2)
        XCTAssertEqual(editor.pendingChanges, ChangeSet(documentChanged: true))
        XCTAssertFalse(editor.canUndo, "view state is not undoable")

        try editor.apply(.deletePage(ids[2]))   // originalIndex 2
        XCTAssertEqual(editor.document.lastViewedPageIndex, 1)
        try editor.apply(.deletePage(ids[1]))   // originalIndex 1; one page left
        XCTAssertThrowsEditingError(try editor.apply(.restorePage(ids[0])), .deletedPageNotFound(ids[0]))
        try editor.apply(.restorePage(ids[2]))
        XCTAssertEqual(editor.document.pageIDs, [ids[0], ids[2]], "index min(2, 1) = 1")
        try editor.apply(.restorePage(ids[1]))
        XCTAssertEqual(editor.document.pageIDs, [ids[0], ids[1], ids[2]])
        XCTAssertTrue(editor.snapshot.validate().isEmpty)
    }

    func testInsertRejectsBadIndexAndDuplicateIDs() throws {
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 2), clock: ManualClock())
        let before = editor.snapshot
        let page = editor.makeNewPage()
        XCTAssertThrowsEditingError(try editor.apply(.insertPage(page, at: 3)), .invalidIndex(3))
        XCTAssertThrowsEditingError(try editor.apply(.insertPage(page, at: -1)), .invalidIndex(-1))
        XCTAssertThrowsEditingError(try editor.apply(.insertPages([page, page], at: 0)), .duplicateID(page.id.description))
        XCTAssertThrowsEditingError(try editor.apply(.insertPage(editor.page(editor.document.pageIDs[0])!, at: 0)),
                                    .duplicateID(editor.document.pageIDs[0].description))
        XCTAssertThrowsEditingError(try editor.apply(.duplicatePage(source: page.id, copy: editor.makeNewPage(), at: 0)), .pageNotFound(page.id))
        XCTAssertEqual(editor.snapshot, before)
        XCTAssertFalse(editor.canUndo)
        try editor.apply(.insertPages([page, editor.makeNewPage()], at: 2))
        XCTAssertEqual(editor.document.pageCount, 4)
        XCTAssertEqual(editor.document.pageIDs[2], page.id)
    }

    // MARK: Locking

    func testLockedObjectsRejectTransformRemoveAndUpdateButAcceptUnlock() throws {
        var snap = EditingFixture.snapshot(pageCount: 1)
        let pageID = snap.document.pageIDs[0]
        let locked = EditingFixture.text("locked", frame: PageRect(x: 0, y: 0, width: 10, height: 10), locked: true)
        let free = EditingFixture.shape(frame: PageRect(x: 50, y: 50, width: 10, height: 10))
        snap.pages[pageID]!.objects = [locked, free]
        let editor = DocumentEditor(snapshot: snap, clock: ManualClock())
        let before = editor.snapshot

        XCTAssertThrowsEditingError(try editor.apply(.transformObjects(pageID, [free.id, locked.id], .translation(x: 1, y: 1))), .objectLocked(locked.id))
        XCTAssertThrowsEditingError(try editor.apply(.removeObjects(pageID, [locked.id])), .objectLocked(locked.id))
        var edited = locked; edited.isLocked = false
        XCTAssertThrowsEditingError(try editor.apply(.updateObject(pageID, edited)), .objectLocked(locked.id))
        XCTAssertEqual(editor.snapshot, before, "a rejected command changes nothing, not even the unlocked member")
        XCTAssertFalse(editor.canUndo)

        try editor.apply(.setObjectsLocked(pageID, [locked.id], false))
        XCTAssertFalse(editor.page(pageID)!.object(locked.id)!.isLocked)
        try editor.apply(.transformObjects(pageID, [locked.id], .translation(x: 1, y: 1)))
        XCTAssertEqual(editor.page(pageID)!.object(locked.id)!.frame, PageRect(x: 1, y: 1, width: 10, height: 10))
        try editor.apply(.setObjectsLocked(pageID, [locked.id, free.id], true))
        XCTAssertTrue(editor.page(pageID)!.objects.allSatisfy(\.isLocked))
        editor.undo(); editor.undo(); editor.undo()
        XCTAssertEqual(editor.snapshot, before)
    }

    // MARK: Undo bookkeeping

    func testUndoLimitDropsOldestRecords() throws {
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 1), clock: ManualClock())
        editor.undoLimit = 3
        for i in 1...5 { try editor.apply(.setTitle("Title \(i)")) }
        XCTAssertEqual(editor.undoStack.count, 3)
        XCTAssertEqual(editor.undoStack.map { $0.afterDocument.title }, ["Title 3", "Title 4", "Title 5"])
        editor.undo(); editor.undo(); editor.undo()
        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(editor.document.title, "Title 2", "the two oldest edits can no longer be undone")
    }

    func testRedoIsClearedByANewCommand() throws {
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 1), clock: ManualClock())
        try editor.apply(.setTitle("A"))
        try editor.apply(.setTitle("B"))
        editor.undo()
        XCTAssertTrue(editor.canRedo)
        XCTAssertEqual(editor.document.title, "A")
        try editor.apply(.setFavorite(true))
        XCTAssertFalse(editor.canRedo)
        XCTAssertNil(editor.redo())
        XCTAssertEqual(editor.document.title, "A")
        XCTAssertTrue(editor.document.isFavorite)
        XCTAssertEqual(editor.undoStack.map(\.name), ["Rename", "Favorite"])
    }

    func testUndoRedoOnEmptyStacksReturnNil() {
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 1), clock: ManualClock())
        XCTAssertNil(editor.undo())
        XCTAssertNil(editor.redo())
        XCTAssertEqual(editor.pendingChanges, .empty)
    }

    func testPendingChangesListExactlyTheTouchedPages() throws {
        let clock = ManualClock(start: EditingFixture.start)
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 3), clock: clock)
        let ids = editor.document.pageIDs
        XCTAssertEqual(editor.pendingChanges, .empty)

        try editor.apply(.setPageBookmark(ids[1], true))
        XCTAssertEqual(editor.pendingChanges, ChangeSet(changedPageIDs: [ids[1]]))
        XCTAssertEqual(editor.page(ids[1])!.modifiedAt, clock.now())
        XCTAssertEqual(editor.page(ids[0])!.modifiedAt, EditingFixture.start)

        clock.advance(by: 2)
        try editor.apply(.setTitle("New"))
        XCTAssertEqual(editor.pendingChanges, ChangeSet(changedPageIDs: [ids[1]], documentChanged: true))
        XCTAssertEqual(editor.document.modifiedAt, clock.now())

        let ink = EditingFixture.inkAsset(9)
        editor.registerPendingAsset(ink)
        XCTAssertEqual(editor.snapshot.assets[ink.asset.id], ink.asset, "registered asset record enters the snapshot")
        try editor.apply(.replaceInk(ids[2], editor.firstInkLayerID(of: ids[2]), dataAssetID: ink.asset.id))
        XCTAssertEqual(editor.pendingChanges, ChangeSet(changedPageIDs: [ids[1], ids[2]], documentChanged: true, newAssets: [ink]))
        XCTAssertEqual(editor.undoStack.count, 3, "asset registration is not an undo step")

        let taken = editor.takePendingChanges()
        XCTAssertEqual(taken.changedPageIDs, [ids[1], ids[2]])
        XCTAssertEqual(taken.newAssets, [ink])
        XCTAssertEqual(editor.pendingChanges, .empty)

        editor.undo()   // replaceInk
        XCTAssertEqual(editor.pendingChanges, ChangeSet(changedPageIDs: [ids[2]]))
        editor.undo()   // setTitle
        XCTAssertEqual(editor.pendingChanges, ChangeSet(changedPageIDs: [ids[2]], documentChanged: true))
        XCTAssertTrue(editor.snapshot.validate().isEmpty)
    }

    func testResetClearsUndoRedoAndPendingChanges() throws {
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 1), clock: ManualClock())
        try editor.apply(.setTitle("A"))
        try editor.apply(.setTitle("B"))
        editor.undo()
        let replacement = EditingFixture.snapshot(pageCount: 2)
        editor.reset(to: replacement)
        XCTAssertEqual(editor.snapshot, replacement)
        XCTAssertFalse(editor.canUndo)
        XCTAssertFalse(editor.canRedo)
        XCTAssertEqual(editor.pendingChanges, .empty)
    }

    // MARK: Objects

    func testAddRemoveUpdateReorderObjectsOnTheSingleArray() throws {
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 1), clock: ManualClock())
        let pageID = editor.document.pageIDs[0]
        let a = EditingFixture.text("a", frame: PageRect(x: 0, y: 0, width: 10, height: 10))
        let b = EditingFixture.shape(frame: PageRect(x: 0, y: 0, width: 10, height: 10))
        let c = EditingFixture.tape(frame: PageRect(x: 0, y: 0, width: 10, height: 10))
        let d = EditingFixture.image(AssetID(), frame: PageRect(x: 0, y: 0, width: 10, height: 10))
        try editor.apply(.addObject(pageID, a, at: nil))
        try editor.apply(.addObjects(pageID, [b, c]))
        try editor.apply(.addObject(pageID, d, at: 0))
        XCTAssertEqual(editor.page(pageID)!.objects.map(\.id), [d.id, a.id, b.id, c.id])
        XCTAssertThrowsEditingError(try editor.apply(.addObject(pageID, a, at: nil)), .duplicateID(a.id.description))
        XCTAssertThrowsEditingError(try editor.apply(.addObject(pageID, EditingFixture.text(frame: .unit), at: 7)), .invalidIndex(7))
        XCTAssertThrowsEditingError(try editor.apply(.addObjects(pageID, [EditingFixture.text(frame: .unit), b])), .duplicateID(b.id.description))

        try editor.apply(.bringToFront(pageID, [d.id, a.id]))
        XCTAssertEqual(editor.page(pageID)!.objects.map(\.id), [b.id, c.id, d.id, a.id], "relative order kept")
        try editor.apply(.sendToBack(pageID, [a.id, c.id]))
        XCTAssertEqual(editor.page(pageID)!.objects.map(\.id), [c.id, a.id, b.id, d.id])
        try editor.apply(.reorderObject(pageID, d.id, to: 1))
        XCTAssertEqual(editor.page(pageID)!.objects.map(\.id), [c.id, d.id, a.id, b.id])
        XCTAssertThrowsEditingError(try editor.apply(.reorderObject(pageID, d.id, to: 4)), .invalidIndex(4))

        var edited = a
        edited.content = .text(TextContent(text: "edited", fontSize: 20))
        edited.rotation = 0.5
        try editor.apply(.updateObject(pageID, edited))
        XCTAssertEqual(editor.page(pageID)!.object(a.id), edited)
        let missing = EditingFixture.text(frame: .unit)
        XCTAssertThrowsEditingError(try editor.apply(.updateObject(pageID, missing)), .objectNotFound(missing.id))

        try editor.apply(.removeObjects(pageID, [a.id, c.id]))
        XCTAssertEqual(editor.page(pageID)!.objects.map(\.id), [d.id, b.id])
        XCTAssertThrowsEditingError(try editor.apply(.removeObjects(pageID, [a.id])), .objectNotFound(a.id))
        let ghost = PageID()
        XCTAssertThrowsEditingError(try editor.apply(.removeObjects(ghost, [b.id])), .pageNotFound(ghost))
    }

    func testTransformRules() throws {
        var snap = EditingFixture.snapshot(pageCount: 1)
        let pageID = snap.document.pageIDs[0]
        let a = EditingFixture.text("a", frame: PageRect(x: 100, y: 100, width: 50, height: 50))
        let b = EditingFixture.shape(frame: PageRect(x: 200, y: 100, width: 20, height: 40))
        let tilted = EditingFixture.text("t", frame: PageRect(x: 0, y: 0, width: 40, height: 10), rotation: 0.3)
        snap.pages[pageID]!.objects = [a, b, tilted]
        let editor = DocumentEditor(snapshot: snap, clock: ManualClock())

        // Scale about a pivot: bounding box of the transformed corners, rotation kept.
        let scale = PageTransform.translation(x: -100, y: -100).concatenating(.scale(2)).concatenating(.translation(x: 100, y: 100))
        try editor.apply(.transformObjects(pageID, [a.id, b.id, tilted.id], scale))
        XCTAssertEqual(editor.page(pageID)!.object(a.id)!.frame, PageRect(x: 100, y: 100, width: 100, height: 100))
        XCTAssertEqual(editor.page(pageID)!.object(b.id)!.frame, PageRect(x: 300, y: 100, width: 40, height: 80))
        XCTAssertRectEqual(editor.page(pageID)!.object(tilted.id)!.frame, PageRect(x: -100, y: -100, width: 80, height: 20))
        XCTAssertEqual(editor.page(pageID)!.object(tilted.id)!.rotation, 0.3)
        editor.undo()

        // Pure rotation about a common pivot: centers move, sizes kept, angle added.
        let rotate = PageTransform.rotation(radians: .pi / 2, about: PagePoint(x: 200, y: 200))
        try editor.apply(.transformObjects(pageID, [a.id, b.id, tilted.id], rotate))
        let ra = editor.page(pageID)!.object(a.id)!
        XCTAssertRectEqual(ra.frame, PageRect(x: 250, y: 100, width: 50, height: 50))
        XCTAssertEqual(ra.rotation, .pi / 2, accuracy: 1e-9)
        let rb = editor.page(pageID)!.object(b.id)!
        XCTAssertRectEqual(rb.frame, PageRect(x: 270, y: 190, width: 20, height: 40))
        XCTAssertEqual(rb.rotation, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(editor.page(pageID)!.object(tilted.id)!.rotation, 0.3 + .pi / 2, accuracy: 1e-9)
        // The rotated object's bounds are the bounds of the rotated original.
        XCTAssertRectEqual(ra.bounds, a.frame.applying(rotate), accuracy: 1e-9)
        editor.undo()
        XCTAssertEqual(editor.snapshot, snap)

        // Rotation combined with scale is a general transform: bounding box, rotation unchanged.
        let general = PageTransform.rotation(radians: .pi / 4).concatenating(.scale(2))
        try editor.apply(.transformObjects(pageID, [a.id], general))
        XCTAssertRectEqual(editor.page(pageID)!.object(a.id)!.frame, a.frame.applying(general))
        XCTAssertEqual(editor.page(pageID)!.object(a.id)!.rotation, 0)
    }

    func testClearPageRemovesObjectsAndEmptiesInkButKeepsMetadata() throws {
        var snap = EditingFixture.snapshot(pageCount: 2)
        let pageID = snap.document.pageIDs[0]
        let ink = EditingFixture.inkAsset(3)
        snap.assets[ink.asset.id] = ink.asset
        snap.pages[pageID]!.objects = [EditingFixture.text(frame: .unit), EditingFixture.tape(frame: .unit, locked: true)]
        snap.pages[pageID]!.inkLayers = [InkLayer(dataAssetID: ink.asset.id), InkLayer(dataAssetID: ink.asset.id, isVisible: false)]
        snap.pages[pageID]!.problem = ProblemMetadata(title: "P1")
        snap.pages[pageID]!.isBookmarked = true
        let editor = DocumentEditor(snapshot: snap, clock: ManualClock())
        let layerIDs = snap.pages[pageID]!.inkLayers.map(\.id)

        let changes = try editor.apply(.clearPage(pageID))
        XCTAssertEqual(changes, ChangeSet(changedPageIDs: [pageID]))
        let page = editor.page(pageID)!
        XCTAssertTrue(page.objects.isEmpty, "locked objects are cleared too")
        XCTAssertEqual(page.inkLayers.map(\.id), layerIDs)
        XCTAssertEqual(page.inkLayers.map(\.dataAssetID), [nil, nil])
        XCTAssertEqual(page.inkLayers.map(\.isVisible), [true, false])
        XCTAssertEqual(page.problem?.title, "P1")
        XCTAssertTrue(page.isBookmarked)
        editor.undo()
        XCTAssertEqual(editor.snapshot, snap)
    }

    func testBackgroundAndInkLayerCommands() throws {
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 1), clock: ManualClock())
        let pageID = editor.document.pageIDs[0]
        let layerID = editor.firstInkLayerID(of: pageID)
        let picture = EditingFixture.imageAsset(4)
        editor.registerPendingAsset(picture)
        try editor.apply(.setPageBackground(pageID, .image(picture.asset.id), size: PageSize(width: 300, height: 400)))
        XCTAssertEqual(editor.page(pageID)!.background, .image(picture.asset.id))
        XCTAssertEqual(editor.page(pageID)!.size, PageSize(width: 300, height: 400))
        try editor.apply(.setInkLayerVisible(pageID, layerID, false))
        XCTAssertFalse(editor.page(pageID)!.inkLayers[0].isVisible)
        let ghost = InkLayerID()
        XCTAssertThrowsEditingError(try editor.apply(.replaceInk(pageID, ghost, dataAssetID: nil)), .inkLayerNotFound(ghost))
        XCTAssertThrowsEditingError(try editor.apply(.setInkLayerVisible(pageID, ghost, true)), .inkLayerNotFound(ghost))
        try editor.apply(.setCover(CoverStyle(palette: .moss, pattern: .dots)))
        try editor.apply(.setDefaultTemplate(.cornell))
        XCTAssertEqual(editor.document.cover.palette, .moss)
        XCTAssertEqual(editor.document.defaultTemplate, .cornell)
        XCTAssertEqual(editor.makeNewPage().background, .template(.cornell))
        XCTAssertTrue(editor.snapshot.validate().isEmpty)
    }

    // MARK: Problem Pages and review

    func testProblemMetadataAndReviewCommandsAreUndoableAndInTheSnapshot() throws {
        let clock = ManualClock(start: EditingFixture.start)
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 2), clock: clock)
        let ids = editor.document.pageIDs
        let original = editor.snapshot

        XCTAssertThrowsEditingError(try editor.apply(.setProblemStatus(ids[0], .understood)), .notAProblemPage(ids[0]))
        let meta = ProblemMetadata(title: "Integrate x²", sourceReference: "HW 3", given: "x", find: "∫",
                                   resultRegion: PageRect(x: 10, y: 500, width: 200, height: 60))
        var changes = try editor.apply(.setProblem(ids[0], meta))
        XCTAssertEqual(changes, ChangeSet(changedPageIDs: [ids[0]]))
        XCTAssertEqual(editor.page(ids[0])!.problem, meta)
        XCTAssertTrue(editor.page(ids[0])!.isProblemPage)

        try editor.apply(.setProblemStatus(ids[0], ReviewRules.cycleStatus(meta.status)))
        XCTAssertEqual(editor.page(ids[0])!.problem?.status, .checkAgain)

        let item = ReviewRules.makeReviewItem(pageID: ids[0], region: meta.resultRegion, prompt: "  Redo without notes ", now: clock.now())
        XCTAssertEqual(item.prompt, "Redo without notes")
        XCTAssertEqual(item.history.map(\.action), [.added])
        changes = try editor.apply(.addReviewItem(item))
        XCTAssertEqual(changes, ChangeSet(changedPageIDs: [], documentChanged: true))
        XCTAssertEqual(editor.document.reviewItems, [item])
        XCTAssertThrowsEditingError(try editor.apply(.addReviewItem(item)), .duplicateID(item.id.description))
        let orphan = ReviewRules.makeReviewItem(pageID: PageID(), now: clock.now())
        XCTAssertThrowsEditingError(try editor.apply(.addReviewItem(orphan)), .pageNotFound(orphan.pageID))

        clock.advance(by: 60)
        try editor.apply(.markReviewed(item.id, at: clock.now()))
        var stored = editor.document.reviewItems[0]
        XCTAssertEqual(stored.state, .reviewed)
        XCTAssertEqual(stored.lastReviewedAt, clock.now())
        XCTAssertEqual(stored.history.map(\.action), [.added, .markedReviewed])
        XCTAssertEqual(ReviewRules.pendingItems(in: editor.snapshot), [])

        clock.advance(by: 60)
        try editor.apply(.reopenReview(item.id, at: clock.now()))
        stored = editor.document.reviewItems[0]
        XCTAssertEqual(stored.state, .pending)
        XCTAssertEqual(stored.history.map(\.action), [.added, .markedReviewed, .reopened])
        XCTAssertEqual(ReviewRules.pendingItems(in: editor.snapshot).map(\.id), [item.id])

        let edited = ReviewRules.editingPrompt(stored, prompt: "Redo from memory", at: clock.now())
        try editor.apply(.updateReviewItem(edited))
        XCTAssertEqual(editor.document.reviewItems[0].prompt, "Redo from memory")
        XCTAssertEqual(editor.document.reviewItems[0].history.last?.action, .promptEdited)

        let ghost = ReviewItemID()
        XCTAssertThrowsEditingError(try editor.apply(.markReviewed(ghost, at: clock.now())), .reviewItemNotFound(ghost))
        XCTAssertThrowsEditingError(try editor.apply(.removeReviewItem(ghost)), .reviewItemNotFound(ghost))
        try editor.apply(.removeReviewItem(item.id))
        XCTAssertTrue(editor.document.reviewItems.isEmpty)

        XCTAssertEqual(editor.undoStack.count, 7)
        editor.undo()
        XCTAssertEqual(editor.document.reviewItems.map(\.prompt), ["Redo from memory"])
        editor.undo(); editor.undo()
        XCTAssertEqual(editor.document.reviewItems[0].state, .reviewed)
        editor.undo()
        XCTAssertEqual(editor.document.reviewItems[0], item)
        editor.undo()
        XCTAssertTrue(editor.document.reviewItems.isEmpty)
        editor.undo()
        XCTAssertEqual(editor.page(ids[0])!.problem?.status, .unfinished)
        editor.undo()
        XCTAssertEqual(editor.snapshot, original)
        while editor.canRedo { editor.redo() }
        XCTAssertTrue(editor.document.reviewItems.isEmpty)
        XCTAssertEqual(editor.page(ids[0])!.problem?.status, .checkAgain)
    }

    func testReviewItemsOfDeletedPagesAreHiddenUntilRestore() throws {
        let clock = ManualClock(start: EditingFixture.start)
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 3), clock: clock)
        let ids = editor.document.pageIDs
        let late = ReviewRules.makeReviewItem(pageID: ids[0], now: clock.now().addingTimeInterval(10))
        let early = ReviewRules.makeReviewItem(pageID: ids[0], now: clock.now())
        let third = ReviewRules.makeReviewItem(pageID: ids[2], now: clock.now())
        for item in [third, late, early] { try editor.apply(.addReviewItem(item)) }
        XCTAssertEqual(ReviewRules.pendingItems(in: editor.snapshot).map(\.id), [early.id, late.id, third.id], "page order, then creation time")
        XCTAssertEqual(ReviewRules.pendingCount(in: editor.snapshot), 3)

        try editor.apply(.deletePage(ids[0]))
        XCTAssertEqual(ReviewRules.pendingItems(in: editor.snapshot).map(\.id), [third.id])
        XCTAssertEqual(Set(ReviewRules.itemsOfDeletedPages(in: editor.snapshot).map(\.id)), [early.id, late.id])
        XCTAssertEqual(editor.document.reviewItems.count, 3, "items stay in the document while the page is in the trash")
        XCTAssertTrue(editor.snapshot.validate().isEmpty)

        try editor.apply(.movePage(ids[2], to: 0))
        try editor.apply(.restorePage(ids[0]))
        XCTAssertEqual(editor.document.pageIDs, [ids[0], ids[2], ids[1]])
        XCTAssertEqual(ReviewRules.pendingItems(in: editor.snapshot).map(\.id), [early.id, late.id, third.id])
        XCTAssertEqual(ReviewRules.items(in: editor.snapshot, forPage: ids[0]).map(\.id), [early.id, late.id])
    }

    func testTapeRevealRecordsEventsOnLinkedReviewItems() throws {
        let clock = ManualClock(start: EditingFixture.start)
        var snap = EditingFixture.snapshot(pageCount: 1)
        let pageID = snap.document.pageIDs[0]
        let tape = EditingFixture.tape(frame: PageRect(x: 10, y: 10, width: 100, height: 30), locked: true)
        let text = EditingFixture.text(frame: PageRect(x: 10, y: 50, width: 100, height: 30))
        snap.pages[pageID]!.objects = [tape, text]
        let editor = DocumentEditor(snapshot: snap, clock: clock)
        let item = ReviewRules.makeReviewItem(pageID: pageID, region: tape.frame, answerTapeID: tape.id, now: clock.now())
        let unrelated = ReviewRules.makeReviewItem(pageID: pageID, now: clock.now())
        try editor.apply(.addReviewItem(item))
        try editor.apply(.addReviewItem(unrelated))
        let before = editor.snapshot

        XCTAssertThrowsEditingError(try editor.apply(.setTapeRevealed(pageID, text.id, true)), .objectKindMismatch(text.id, expected: .tape))
        clock.advance(by: 5)
        var changes = try editor.apply(.setTapeRevealed(pageID, tape.id, true))
        XCTAssertEqual(changes, ChangeSet(changedPageIDs: [pageID], documentChanged: true))
        guard case .tape(let revealedTape) = editor.page(pageID)!.object(tape.id)!.content else { return XCTFail("tape expected") }
        XCTAssertTrue(revealedTape.isRevealed, "revealing locked tape is allowed")
        XCTAssertEqual(editor.document.reviewItems[0].history.map(\.action), [.added, .revealed])
        XCTAssertEqual(editor.document.reviewItems[0].history.last?.at, clock.now())
        XCTAssertEqual(editor.document.reviewItems[1].history.map(\.action), [.added], "unlinked item untouched")

        changes = try editor.apply(.setTapeRevealed(pageID, tape.id, true))
        XCTAssertEqual(changes, ChangeSet(changedPageIDs: [pageID]), "no state change: no event, no document change")
        XCTAssertEqual(editor.document.reviewItems[0].history.count, 2)

        try editor.apply(.setTapeRevealed(pageID, tape.id, false))
        XCTAssertEqual(editor.document.reviewItems[0].history.map(\.action), [.added, .revealed, .hidden])

        editor.undo(); editor.undo(); editor.undo()
        XCTAssertEqual(editor.snapshot, before)
    }

    // MARK: Command builders

    func testMakeDuplicateAndCopiesOfPagesUseFreshIDsAndSharedAssets() throws {
        let clock = ManualClock(start: EditingFixture.start)
        var snap = EditingFixture.snapshot(pageCount: 2)
        let ids = snap.document.pageIDs
        let ink = EditingFixture.inkAsset(5), picture = EditingFixture.imageAsset(6)
        snap.assets[ink.asset.id] = ink.asset
        snap.assets[picture.asset.id] = picture.asset
        snap.pages[ids[0]]!.objects = [EditingFixture.image(picture.asset.id, frame: .unit), EditingFixture.text(frame: .unit, locked: true)]
        snap.pages[ids[0]]!.inkLayers = [InkLayer(dataAssetID: ink.asset.id)]
        snap.pages[ids[0]]!.background = .image(picture.asset.id)
        snap.pages[ids[0]]!.problem = ProblemMetadata(title: "P", status: .understood)
        let editor = DocumentEditor(snapshot: snap, clock: clock)
        clock.advance(by: 3)

        let copy = editor.makeDuplicate(of: ids[0])!
        let source = snap.pages[ids[0]]!
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.objects.count, 2)
        XCTAssertTrue(Set(copy.objects.map(\.id)).isDisjoint(with: source.objects.map(\.id)))
        XCTAssertEqual(copy.objects.map(\.content), source.objects.map(\.content))
        XCTAssertEqual(copy.objects.map(\.isLocked), [false, true])
        XCTAssertNotEqual(copy.inkLayers[0].id, source.inkLayers[0].id)
        XCTAssertEqual(copy.inkLayers[0].dataAssetID, ink.asset.id, "ink blob asset is shared")
        XCTAssertEqual(copy.referencedAssetIDs, source.referencedAssetIDs)
        XCTAssertEqual(copy.problem, source.problem)
        XCTAssertEqual(copy.createdAt, clock.now())
        XCTAssertEqual(copy.modifiedAt, clock.now())
        XCTAssertEqual(copy.revisionID, editor.document.revisionHead)
        XCTAssertNil(editor.makeDuplicate(of: PageID()))

        let copies = editor.copiesOfPages([ids[1], PageID(), ids[0]])
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(copies.map(\.size), [source.size, source.size])
        XCTAssertTrue(Set(copies.map(\.id)).isDisjoint(with: ids))
        XCTAssertNotEqual(copies[1].id, copy.id)
        XCTAssertEqual(copies[1].referencedAssetIDs, source.referencedAssetIDs)

        try editor.apply(.duplicatePage(source: ids[0], copy: copy, at: 1))
        XCTAssertEqual(editor.page(ids[0]), source, "duplicating never modifies the source")
        XCTAssertTrue(editor.snapshot.validate().isEmpty)
        XCTAssertThrowsEditingError(try editor.apply(.duplicatePage(source: ids[0], copy: copy, at: 1)), .duplicateID(copy.id.description))
    }

    func testMakeNewPageUsesDocumentDefaults() {
        let clock = ManualClock(start: EditingFixture.start)
        let editor = DocumentEditor(snapshot: EditingFixture.snapshot(pageCount: 1), clock: clock)
        clock.advance(by: 1)
        let page = editor.makeNewPage()
        XCTAssertEqual(page.size, .letter)
        XCTAssertEqual(page.background, .template(.lined))
        XCTAssertEqual(page.inkLayers.count, 1)
        XCTAssertEqual(page.createdAt, clock.now())
        XCTAssertEqual(page.modifiedAt, clock.now())
        XCTAssertEqual(page.revisionID, editor.document.revisionHead)
        let custom = editor.makeNewPage(template: .dotted, size: .a4)
        XCTAssertEqual(custom.background, .template(.dotted))
        XCTAssertEqual(custom.size, .a4)
        XCTAssertNotEqual(custom.id, page.id)
    }
}
