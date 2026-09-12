import Foundation
import DocumentCore

// Hit testing, action availability and clipboard payloads for selections.
// Ink strokes are hit-tested by the ink engine (`InkDrawing.strokeIndices`);
// these rules only cover canvas objects and combine the two in `Selection`.

extension SelectionFilter {
    /// The filter bit that admits objects of `kind`.
    public static func forKind(_ kind: ObjectKind) -> SelectionFilter {
        switch kind {
        case .text: return .text
        case .image: return .images
        case .shape: return .shapes
        case .tape: return .tape
        }
    }
    public func allows(_ kind: ObjectKind) -> Bool { contains(SelectionFilter.forKind(kind)) }
}

extension SelectionRules {

    // MARK: Hit testing

    /// Candidates for lasso selection: unlocked objects admitted by `filter`, in page order.
    private static func candidates(in page: Page, filter: SelectionFilter) -> [CanvasObject] {
        page.objects.filter { !$0.isLocked && filter.allows($0.kind) }
    }

    static func _objects(in page: Page, intersecting rect: PageRect, filter: SelectionFilter) -> [ObjectID] {
        let rect = rect.standardized
        return candidates(in: page, filter: filter).filter { $0.bounds.intersects(rect) }.map(\.id)
    }

    static func _objects(in page: Page, inside polygon: [PagePoint], filter: SelectionFilter) -> [ObjectID] {
        guard polygon.count >= 3 else { return [] }
        return candidates(in: page, filter: filter)
            .filter { object in object.bounds.corners.allSatisfy { Polygon.contains(polygon, $0) } }
            .map(\.id)
    }

    /// Top-most unlocked object under `point`, respecting the compositing order:
    /// tape is drawn last, then text/shapes, then (beneath ink) images. Within a
    /// band the later array element is on top. Containment is exact for rotated
    /// objects: the point is mapped into the object's unit space.
    static func _object(in page: Page, at point: PagePoint) -> ObjectID? {
        let bands: [[ObjectKind]] = [[.tape], [.text, .shape], [.image]]
        for band in bands {
            for object in page.objects.reversed() where !object.isLocked && band.contains(object.kind) {
                if contains(object, point) { return object.id }
            }
        }
        return nil
    }

    /// Exact containment test for a (possibly rotated) object.
    public static func contains(_ object: CanvasObject, _ point: PagePoint) -> Bool {
        if object.rotation == 0 { return object.frame.standardized.contains(point) }
        guard let inverse = object.transform.inverted() else { return object.bounds.contains(point) }
        let local = inverse.apply(point)
        let tolerance = 1e-9
        return local.x >= -tolerance && local.x <= 1 + tolerance && local.y >= -tolerance && local.y <= 1 + tolerance
    }

    // MARK: Actions

    /// Actions valid for every member of the selection.
    ///
    /// - `paste` and `addToReview` are always available (they act on the page, not the members).
    /// - Any locked member removes every editing action except `copy` (and `unlock` when all members are locked).
    /// - `lock`, `bringToFront`, `sendToBack` need object members only (ink cannot be locked or reordered).
    /// - `recolor` needs every member to be ink, text or shape.
    /// - `editText` / `cropImage` need exactly one object member (text / image) and no ink.
    /// - `revealTape` / `hideTape` need every member to be tape (locked tape included) and at least one
    ///   member that is currently hidden / revealed.
    static func _availableActions(for selection: Selection, in page: Page) -> Set<SelectionAction> {
        var actions: Set<SelectionAction> = [.paste, .addToReview]
        let members = selection.objectIDs.compactMap { page.object($0) }.sorted { $0.id < $1.id }
        let hasInk = selection.hasInk
        guard !members.isEmpty || hasInk else { return actions }

        let objectsOnly = !hasInk
        let kinds = Set(members.map(\.kind))
        if objectsOnly, kinds == [.tape] {
            if members.contains(where: { if case .tape(let t) = $0.content { return !t.isRevealed } else { return false } }) { actions.insert(.revealTape) }
            if members.contains(where: { if case .tape(let t) = $0.content { return t.isRevealed } else { return false } }) { actions.insert(.hideTape) }
        }

        let lockedCount = members.filter(\.isLocked).count
        if lockedCount > 0 {
            actions.insert(.copy)
            if objectsOnly, lockedCount == members.count { actions.insert(.unlock) }
            return actions
        }

        actions.formUnion([.move, .resize, .rotate, .copy, .cut, .duplicate, .delete])
        if objectsOnly { actions.formUnion([.lock, .bringToFront, .sendToBack]) }
        if kinds.isSubset(of: [.text, .shape]) { actions.insert(.recolor) }
        if objectsOnly, members.count == 1 {
            if kinds == [.text] { actions.insert(.editText) }
            if kinds == [.image] { actions.insert(.cropImage) }
        }
        return actions
    }

    // MARK: Bounds

    static func _bounds(of selection: Selection, in page: Page, inkBounds: PageRect?) -> PageRect? {
        var result: PageRect? = selection.hasInk ? inkBounds : nil
        for object in page.objects where selection.objectIDs.contains(object.id) {
            result = result.map { $0.union(object.bounds) } ?? object.bounds
        }
        return result
    }
}

// MARK: - Clipboard

/// Copied selection content. Objects keep their page-space frames; the ink
/// strokes of the selection, if any, are an engine blob the app extracted and
/// registered as an asset (`inkAssetID`). Pasting objects is a plain command
/// (`pasteCommands`); pasting ink needs the ink engine to append the blob to
/// the destination layer and then a `replaceInk` command, which the app does
/// because the editor never inspects ink bytes.
public struct ClipboardPayload: Hashable, Sendable {
    public var objects: [CanvasObject]
    public var inkAssetID: AssetID?
    /// Size of the page the content was copied from, so a paste onto a differently sized page can be clamped or scaled by the UI.
    public var sourcePageSize: PageSize

    public init(objects: [CanvasObject], inkAssetID: AssetID? = nil, sourcePageSize: PageSize) {
        self.objects = objects; self.inkAssetID = inkAssetID; self.sourcePageSize = sourcePageSize
    }

    /// The selected objects of `page` in page order (locked ones included: copying does not modify them).
    public static func copying(_ selection: Selection, from page: Page, inkAssetID: AssetID? = nil) -> ClipboardPayload {
        ClipboardPayload(objects: page.objects.filter { selection.objectIDs.contains($0.id) },
                         inkAssetID: inkAssetID, sourcePageSize: page.size)
    }

    public var isEmpty: Bool { objects.isEmpty && inkAssetID == nil }

    /// Commands that paste the objects onto `pageID`: one `addObjects` with fresh
    /// object IDs, frames offset by `offset`, unlocked, `createdAt = now`. Empty when
    /// there are no objects (ink is handled by the app, see the type comment).
    public func pasteCommands(into pageID: PageID, offset: PagePoint, now: Date = Date()) -> [EditCommand] {
        guard !objects.isEmpty else { return [] }
        let pasted = objects.map { object -> CanvasObject in
            var o = object
            o.id = ObjectID()
            o.frame = object.frame.offsetBy(dx: offset.x, dy: offset.y)
            o.isLocked = false
            o.createdAt = now
            return o
        }
        return [.addObjects(pageID, pasted)]
    }
}
