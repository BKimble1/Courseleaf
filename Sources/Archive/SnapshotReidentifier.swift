import Foundation
import DocumentCore

/// Produces a copy of a snapshot under a new document identity: fresh page,
/// object, ink-layer, review-item and revision IDs with every internal
/// reference remapped. Asset IDs are kept (assets are content-addressed and
/// scoped to the document). Used for "restore as a copy" and "duplicate".
public enum SnapshotReidentifier {
    public static func copy(_ snapshot: DocumentSnapshot, newDocumentID: DocumentID = DocumentID(),
                            makeUUID: () -> UUID = { UUID() }) -> DocumentSnapshot {
        var pageMap: [PageID: PageID] = [:]
        var objectMap: [ObjectID: ObjectID] = [:]
        var layerMap: [InkLayerID: InkLayerID] = [:]
        var reviewMap: [ReviewItemID: ReviewItemID] = [:]
        var revisionMap: [RevisionID: RevisionID] = [:]

        func mapPage(_ id: PageID) -> PageID {
            if let m = pageMap[id] { return m }
            let n = PageID(rawValue: makeUUID()); pageMap[id] = n; return n
        }
        func mapObject(_ id: ObjectID) -> ObjectID {
            if let m = objectMap[id] { return m }
            let n = ObjectID(rawValue: makeUUID()); objectMap[id] = n; return n
        }
        func mapLayer(_ id: InkLayerID) -> InkLayerID {
            if let m = layerMap[id] { return m }
            let n = InkLayerID(rawValue: makeUUID()); layerMap[id] = n; return n
        }
        func mapReview(_ id: ReviewItemID) -> ReviewItemID {
            if let m = reviewMap[id] { return m }
            let n = ReviewItemID(rawValue: makeUUID()); reviewMap[id] = n; return n
        }
        func mapRevision(_ id: RevisionID) -> RevisionID {
            if let m = revisionMap[id] { return m }
            let n = RevisionID(rawValue: makeUUID()); revisionMap[id] = n; return n
        }
        func mapPageValue(_ page: Page) -> Page {
            var p = page
            p.id = mapPage(page.id)
            p.revisionID = mapRevision(page.revisionID)
            p.objects = page.objects.map { var o = $0; o.id = mapObject($0.id); return o }
            p.inkLayers = page.inkLayers.map { var l = $0; l.id = mapLayer($0.id); return l }
            return p
        }

        // Deterministic traversal order so a seeded `makeUUID` gives reproducible output.
        var doc = snapshot.document
        doc.id = newDocumentID
        doc.pageIDs = snapshot.document.pageIDs.map(mapPage)
        var pages: [PageID: Page] = [:]
        for id in snapshot.document.pageIDs { if let p = snapshot.pages[id] { pages[mapPage(id)] = mapPageValue(p) } }
        doc.deletedPages = snapshot.document.deletedPages.map { d in
            DeletedPage(page: mapPageValue(d.page), originalIndex: d.originalIndex, deletedAt: d.deletedAt)
        }
        for id in snapshot.pages.keys.sorted() where pages[mapPage(id)] == nil {
            pages[mapPage(id)] = mapPageValue(snapshot.pages[id]!)
        }
        doc.reviewItems = snapshot.document.reviewItems.map { item in
            var r = item
            r.id = mapReview(item.id)
            r.pageID = mapPage(item.pageID)
            r.answerTapeID = item.answerTapeID.map(mapObject)
            return r
        }
        doc.revisionHead = mapRevision(snapshot.document.revisionHead)
        // Remaining revisions in history order (sequence), so the mapping does not depend on the old IDs.
        let orderedRevisionIDs = snapshot.revisions.keys.sorted { a, b in
            let ra = snapshot.revisions[a]!, rb = snapshot.revisions[b]!
            return ra.sequence != rb.sequence ? ra.sequence < rb.sequence : a < b
        }
        var revisions: [RevisionID: Revision] = [:]
        for id in orderedRevisionIDs {
            var rev = snapshot.revisions[id]!
            rev.id = mapRevision(id)
            rev.parentIDs = rev.parentIDs.map(mapRevision)
            rev.changedPageIDs = rev.changedPageIDs.map(mapPage)
            revisions[rev.id] = rev
        }
        return DocumentSnapshot(document: doc, pages: pages, assets: snapshot.assets, revisions: revisions)
    }
}
