import XCTest
import DocumentCore
@testable import Editing

final class SelectionTests: XCTestCase {

    private func page(_ objects: [CanvasObject]) -> Page {
        Page(size: .letter, background: .template(.blank), objects: objects, revisionID: RevisionID(),
             createdAt: EditingFixture.start, modifiedAt: EditingFixture.start)
    }

    // MARK: Hit testing

    func testRectHitTestUsesRotatedBoundsSkipsLockedAndAppliesFilters() {
        // 100x20 frame at (100,100) rotated 90°: center (150,110), bounds x 140...160, y 60...160.
        let rotated = EditingFixture.text("r", frame: PageRect(x: 100, y: 100, width: 100, height: 20), rotation: .pi / 2)
        let locked = EditingFixture.shape(frame: PageRect(x: 145, y: 100, width: 10, height: 10), locked: true)
        let image = EditingFixture.image(AssetID(), frame: PageRect(x: 140, y: 140, width: 50, height: 50))
        let far = EditingFixture.tape(frame: PageRect(x: 500, y: 500, width: 10, height: 10))
        let p = page([rotated, locked, image, far])

        XCTAssertRectEqual(rotated.bounds, PageRect(x: 140, y: 60, width: 20, height: 100))
        XCTAssertEqual(SelectionRules.objects(in: p, intersecting: PageRect(x: 145, y: 65, width: 5, height: 5)), [rotated.id])
        XCTAssertEqual(SelectionRules.objects(in: p, intersecting: PageRect(x: 100, y: 100, width: 10, height: 5)), [],
                       "the unrotated frame corner is outside the rotated bounds")
        XCTAssertEqual(SelectionRules.objects(in: p, intersecting: PageRect(x: 140, y: 100, width: 20, height: 50)), [rotated.id, image.id],
                       "locked object is never hit")
        XCTAssertEqual(SelectionRules.objects(in: p, intersecting: PageRect(x: 140, y: 100, width: 20, height: 50), filter: [.images]), [image.id])
        XCTAssertEqual(SelectionRules.objects(in: p, intersecting: PageRect(x: 140, y: 100, width: 20, height: 50), filter: [.ink, .shapes]), [])
        XCTAssertEqual(SelectionRules.objects(in: p, intersecting: PageRect(x: 200, y: 200, width: -30, height: -30)), [image.id],
                       "negative-size rects are standardized: (170,170,30,30) touches only the image")
    }

    func testPolygonHitTestRequiresWholeBoundsInside() {
        let inside = EditingFixture.text(frame: PageRect(x: 20, y: 20, width: 10, height: 10))
        let straddling = EditingFixture.shape(frame: PageRect(x: 90, y: 20, width: 30, height: 10))
        let lockedInside = EditingFixture.tape(frame: PageRect(x: 40, y: 40, width: 10, height: 10), locked: true)
        let p = page([inside, straddling, lockedInside])
        let square = [PagePoint(x: 0, y: 0), PagePoint(x: 100, y: 0), PagePoint(x: 100, y: 100), PagePoint(x: 0, y: 100)]
        XCTAssertEqual(SelectionRules.objects(in: p, inside: square), [inside.id])
        XCTAssertEqual(SelectionRules.objects(in: p, inside: square, filter: [.shapes]), [])
        XCTAssertEqual(SelectionRules.objects(in: p, inside: [PagePoint(x: 0, y: 0), PagePoint(x: 1, y: 1)]), [], "degenerate lasso")
    }

    func testPointHitTestIsExactForRotationAndFollowsCompositingOrder() {
        let rotated = EditingFixture.text("r", frame: PageRect(x: 100, y: 100, width: 100, height: 20), rotation: .pi / 2)
        let p = page([rotated])
        XCTAssertEqual(SelectionRules.object(in: p, at: PagePoint(x: 150, y: 70)), rotated.id)
        XCTAssertNil(SelectionRules.object(in: p, at: PagePoint(x: 105, y: 105)), "inside the unrotated frame but outside the rotated object")
        // 100x20 frame rotated 45° about (150,110): bounds ≈ x 107.6...192.4, y 67.6...152.4, but the corner is empty.
        let diamond = EditingFixture.text("d", frame: PageRect(x: 100, y: 100, width: 100, height: 20), rotation: .pi / 4)
        XCTAssertTrue(diamond.bounds.contains(PagePoint(x: 108, y: 68)))
        XCTAssertNil(SelectionRules.object(in: page([diamond]), at: PagePoint(x: 108, y: 68)), "inside the axis-aligned bounds corner but outside the object")
        XCTAssertEqual(SelectionRules.object(in: page([diamond]), at: PagePoint(x: 150, y: 110)), diamond.id)
        XCTAssertEqual(SelectionRules.object(in: page([diamond]), at: PagePoint(x: 150 + 30 * cos(Double.pi / 4), y: 110 + 30 * sin(Double.pi / 4))), diamond.id,
                       "a point along the rotated long axis")

        let area = PageRect(x: 0, y: 0, width: 100, height: 100)
        let image = EditingFixture.image(AssetID(), frame: area)
        let lower = EditingFixture.text("lower", frame: area)
        let upper = EditingFixture.text("upper", frame: area)
        let tape = EditingFixture.tape(frame: area)
        let lockedTop = EditingFixture.shape(frame: area, locked: true)
        let point = PagePoint(x: 50, y: 50)
        XCTAssertEqual(SelectionRules.object(in: page([lower, upper]), at: point), upper.id, "later array element is on top")
        XCTAssertEqual(SelectionRules.object(in: page([upper, lower]), at: point), lower.id)
        XCTAssertEqual(SelectionRules.object(in: page([upper, image]), at: point), upper.id, "images render beneath text regardless of order")
        XCTAssertEqual(SelectionRules.object(in: page([tape, upper]), at: point), tape.id, "tape is drawn last")
        XCTAssertEqual(SelectionRules.object(in: page([lower, lockedTop]), at: point), lower.id, "locked objects are skipped")
        XCTAssertEqual(SelectionRules.object(in: page([image]), at: point), image.id)
        XCTAssertNil(SelectionRules.object(in: page([image]), at: PagePoint(x: 150, y: 150)))
    }

    // MARK: Available actions

    private func actions(_ objects: [CanvasObject], selecting: [CanvasObject], ink: Bool = false) -> Set<SelectionAction> {
        let p = page(objects)
        let selection = Selection(pageID: p.id, objectIDs: Set(selecting.map(\.id)),
                                  strokeIndices: ink ? [p.inkLayers[0].id: [0, 1]] : [:])
        return SelectionRules.availableActions(for: selection, in: p)
    }

    func testAvailableActionsMatrix() {
        let text = EditingFixture.text(frame: .unit)
        let image = EditingFixture.image(AssetID(), frame: .unit)
        let shape = EditingFixture.shape(frame: .unit)
        let hiddenTape = EditingFixture.tape(frame: .unit, revealed: false)
        let shownTape = EditingFixture.tape(frame: .unit, revealed: true)
        let lockedText = EditingFixture.text(frame: .unit, locked: true)
        let lockedTape = EditingFixture.tape(frame: .unit, locked: true)
        let all = [text, image, shape, hiddenTape, shownTape, lockedText, lockedTape]
        let editing: Set<SelectionAction> = [.move, .resize, .rotate, .copy, .cut, .duplicate, .delete]
        let objectOnly: Set<SelectionAction> = [.lock, .bringToFront, .sendToBack]
        let always: Set<SelectionAction> = [.paste, .addToReview]

        XCTAssertEqual(actions(all, selecting: []), always)
        XCTAssertEqual(actions(all, selecting: [text]), always.union(editing).union(objectOnly).union([.recolor, .editText]))
        XCTAssertEqual(actions(all, selecting: [image]), always.union(editing).union(objectOnly).union([.cropImage]))
        XCTAssertEqual(actions(all, selecting: [shape]), always.union(editing).union(objectOnly).union([.recolor]))
        XCTAssertEqual(actions(all, selecting: [text, shape]), always.union(editing).union(objectOnly).union([.recolor]), "two texts/shapes: no editText")
        XCTAssertEqual(actions(all, selecting: [text, image]), always.union(editing).union(objectOnly), "image blocks recolor, pair blocks editText/cropImage")
        XCTAssertEqual(actions(all, selecting: [], ink: true), always.union(editing).union([.recolor]), "ink only: recolor, no lock/reorder")
        XCTAssertEqual(actions(all, selecting: [text], ink: true), always.union(editing).union([.recolor]), "ink + text: no editText, no lock")
        XCTAssertEqual(actions(all, selecting: [image], ink: true), always.union(editing), "ink + image: no recolor, no crop")
        XCTAssertEqual(actions(all, selecting: [hiddenTape]), always.union(editing).union(objectOnly).union([.revealTape]))
        XCTAssertEqual(actions(all, selecting: [shownTape]), always.union(editing).union(objectOnly).union([.hideTape]))
        XCTAssertEqual(actions(all, selecting: [hiddenTape, shownTape]), always.union(editing).union(objectOnly).union([.revealTape, .hideTape]))
        XCTAssertEqual(actions(all, selecting: [hiddenTape, text]), always.union(editing).union(objectOnly), "mixed with text: no tape actions, no recolor")
        XCTAssertEqual(actions(all, selecting: [lockedText]), always.union([.copy, .unlock]))
        XCTAssertEqual(actions(all, selecting: [lockedText, text]), always.union([.copy]), "mixed lock state: neither lock nor unlock")
        XCTAssertEqual(actions(all, selecting: [lockedTape]), always.union([.copy, .unlock, .revealTape]), "locked tape may still be revealed")
        XCTAssertEqual(actions(all, selecting: [lockedText], ink: true), always.union([.copy]))
        XCTAssertEqual(actions(all, selecting: [EditingFixture.text(frame: .unit)]), always, "IDs not on the page are ignored")
    }

    func testSelectionBounds() {
        let a = EditingFixture.text(frame: PageRect(x: 10, y: 10, width: 20, height: 20))
        let b = EditingFixture.shape(frame: PageRect(x: 100, y: 50, width: 10, height: 10))
        let rotated = EditingFixture.text("r", frame: PageRect(x: 100, y: 100, width: 100, height: 20), rotation: .pi / 2)
        let p = page([a, b, rotated])
        let layer = p.inkLayers[0].id
        XCTAssertNil(SelectionRules.bounds(of: Selection(pageID: p.id), in: p, inkBounds: PageRect(x: 0, y: 0, width: 5, height: 5)),
                     "ink bounds count only when the selection has ink")
        XCTAssertEqual(SelectionRules.bounds(of: Selection(pageID: p.id, objectIDs: [a.id, b.id]), in: p, inkBounds: nil),
                       PageRect(x: 10, y: 10, width: 100, height: 50))
        let withInk = Selection(pageID: p.id, objectIDs: [a.id], strokeIndices: [layer: [3]])
        XCTAssertEqual(SelectionRules.bounds(of: withInk, in: p, inkBounds: PageRect(x: 0, y: 40, width: 5, height: 5)),
                       PageRect(x: 0, y: 10, width: 30, height: 35))
        XCTAssertEqual(SelectionRules.bounds(of: withInk, in: p, inkBounds: nil), a.bounds, "unknown ink bounds: object bounds only")
        XCTAssertRectEqual(SelectionRules.bounds(of: Selection(pageID: p.id, objectIDs: [rotated.id]), in: p, inkBounds: nil)!,
                           PageRect(x: 140, y: 60, width: 20, height: 100))
        XCTAssertTrue(Selection(pageID: p.id).isEmpty)
        XCTAssertTrue(Selection(pageID: p.id, strokeIndices: [layer: []]).isEmpty)
        XCTAssertTrue(withInk.hasInk)
    }

    // MARK: Clipboard

    func testClipboardPasteGivesFreshIDsAndOffsets() throws {
        let clock = ManualClock(start: EditingFixture.start)
        var snap = EditingFixture.snapshot(pageCount: 2)
        let ids = snap.document.pageIDs
        let picture = EditingFixture.imageAsset(7)
        snap.assets[picture.asset.id] = picture.asset
        let text = EditingFixture.text("copy me", frame: PageRect(x: 10, y: 20, width: 100, height: 30), rotation: 0.2)
        let lockedImage = EditingFixture.image(picture.asset.id, frame: PageRect(x: 200, y: 200, width: 50, height: 50), locked: true)
        let skipped = EditingFixture.shape(frame: PageRect(x: 300, y: 300, width: 10, height: 10))
        snap.pages[ids[0]]!.objects = [skipped, lockedImage, text]
        let editor = DocumentEditor(snapshot: snap, clock: clock)
        let sourceBefore = editor.page(ids[0])!

        let selection = Selection(pageID: ids[0], objectIDs: [text.id, lockedImage.id])
        let inkBlob = EditingFixture.inkAsset(8)
        let payload = ClipboardPayload.copying(selection, from: sourceBefore, inkAssetID: inkBlob.asset.id)
        XCTAssertEqual(payload.objects.map(\.id), [lockedImage.id, text.id], "page order, locked objects may be copied")
        XCTAssertEqual(payload.sourcePageSize, .letter)
        XCTAssertEqual(payload.inkAssetID, inkBlob.asset.id)
        XCTAssertFalse(payload.isEmpty)
        XCTAssertTrue(ClipboardPayload(objects: [], sourcePageSize: .letter).isEmpty)
        XCTAssertEqual(ClipboardPayload(objects: [], inkAssetID: inkBlob.asset.id, sourcePageSize: .letter).pasteCommands(into: ids[1], offset: .zero), [],
                       "ink-only payloads produce no object command; the app appends ink through the engine")

        clock.advance(by: 11)
        let commands = payload.pasteCommands(into: ids[1], offset: PagePoint(x: 20, y: 30), now: clock.now())
        XCTAssertEqual(commands.count, 1)
        guard case .addObjects(let target, let pasted) = commands[0] else { return XCTFail("expected addObjects") }
        XCTAssertEqual(target, ids[1])
        XCTAssertEqual(pasted.count, 2)
        XCTAssertTrue(Set(pasted.map(\.id)).isDisjoint(with: [text.id, lockedImage.id]))
        XCTAssertEqual(pasted[0].frame, PageRect(x: 220, y: 230, width: 50, height: 50))
        XCTAssertEqual(pasted[1].frame, PageRect(x: 30, y: 50, width: 100, height: 30))
        XCTAssertEqual(pasted[1].rotation, 0.2)
        XCTAssertEqual(pasted.map(\.content), [lockedImage.content, text.content])
        XCTAssertEqual(pasted.map(\.isLocked), [false, false], "pasted copies are unlocked")
        XCTAssertEqual(pasted.map(\.createdAt), [clock.now(), clock.now()])

        let second = payload.pasteCommands(into: ids[1], offset: PagePoint(x: 20, y: 30), now: clock.now())
        guard case .addObjects(_, let pastedAgain) = second[0] else { return XCTFail("expected addObjects") }
        XCTAssertTrue(Set(pastedAgain.map(\.id)).isDisjoint(with: pasted.map(\.id)), "every paste gets its own IDs")

        for command in commands + second { try editor.apply(command) }
        XCTAssertEqual(editor.page(ids[1])!.objects.count, 4)
        XCTAssertEqual(editor.page(ids[0]), sourceBefore, "source page untouched")
        XCTAssertEqual(editor.pendingChanges, ChangeSet(changedPageIDs: [ids[1]]))
        XCTAssertTrue(editor.snapshot.validate().isEmpty)
        editor.undo(); editor.undo()
        XCTAssertEqual(editor.snapshot, snap)
    }
}
