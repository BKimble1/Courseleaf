import Foundation
import DocumentCore

extension DocumentSnapshot {
    /// A copy of the snapshot with fresh `DocumentID`, `PageID`s, `ObjectID`s,
    /// `InkLayerID`s, `ReviewItemID`s and `RevisionID`s, every cross-reference
    /// (page order, deleted pages, review item page/tape ids, revision parents
    /// and changed pages, page revision ids) rewritten consistently. Assets are
    /// content-addressed and keep their ids. Used by duplicate and by
    /// archive restore "as a copy".
    public func reidentified(documentID: DocumentID = DocumentID()) -> DocumentSnapshot {
        var pageMap: [PageID: PageID] = [:]
        var objectMap: [ObjectID: ObjectID] = [:]
        var layerMap: [InkLayerID: InkLayerID] = [:]
        var reviewMap: [ReviewItemID: ReviewItemID] = [:]
        var revisionMap: [RevisionID: RevisionID] = [:]

        func mapPage(_ id: PageID) -> PageID { if let m = pageMap[id] { return m }; let n = PageID(); pageMap[id] = n; return n }
        func mapObject(_ id: ObjectID) -> ObjectID { if let m = objectMap[id] { return m }; let n = ObjectID(); objectMap[id] = n; return n }
        func mapLayer(_ id: InkLayerID) -> InkLayerID { if let m = layerMap[id] { return m }; let n = InkLayerID(); layerMap[id] = n; return n }
        func mapReview(_ id: ReviewItemID) -> ReviewItemID { if let m = reviewMap[id] { return m }; let n = ReviewItemID(); reviewMap[id] = n; return n }
        func mapRevision(_ id: RevisionID) -> RevisionID { if let m = revisionMap[id] { return m }; let n = RevisionID(); revisionMap[id] = n; return n }

        func rewrite(_ page: Page) -> Page {
            var p = page
            p.id = mapPage(page.id)
            p.revisionID = mapRevision(page.revisionID)
            p.objects = page.objects.map { var o = $0; o.id = mapObject($0.id); return o }
            p.inkLayers = page.inkLayers.map { var l = $0; l.id = mapLayer($0.id); return l }
            return p
        }

        var doc = document
        doc.id = documentID
        doc.pageIDs = document.pageIDs.map(mapPage)
        doc.revisionHead = mapRevision(document.revisionHead)
        var pages: [PageID: Page] = [:]
        for (_, page) in self.pages.sorted(by: { $0.key < $1.key }) {
            let rewritten = rewrite(page)
            pages[rewritten.id] = rewritten
        }
        doc.deletedPages = document.deletedPages.map { d in
            var copy = d
            copy.page = pages[mapPage(d.page.id)] ?? rewrite(d.page)
            return copy
        }
        doc.reviewItems = document.reviewItems.map { item in
            var r = item
            r.id = mapReview(item.id)
            r.pageID = mapPage(item.pageID)
            r.answerTapeID = item.answerTapeID.map(mapObject)
            return r
        }
        var revisions: [RevisionID: Revision] = [:]
        for (_, rev) in self.revisions.sorted(by: { $0.key < $1.key }) {
            var r = rev
            r.id = mapRevision(rev.id)
            r.parentIDs = rev.parentIDs.map(mapRevision)
            r.changedPageIDs = rev.changedPageIDs.map(mapPage)
            revisions[r.id] = r
        }
        return DocumentSnapshot(document: doc, pages: pages, assets: assets, revisions: revisions)
    }
}
