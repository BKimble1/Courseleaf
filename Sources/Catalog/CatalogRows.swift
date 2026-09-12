import Foundation
import DocumentCore

/// Which documents a listing query returns.
public enum CatalogScope: Hashable, Sendable {
    /// Documents filed in a folder; `nil` is the library root (unfiled notebooks;
    /// unfiled quick notes belong to `.inbox`).
    case folder(FolderID?)
    /// Most recently opened (or, when never opened, modified) documents, newest first.
    case recents(limit: Int)
    case favorites
    /// Quick notes that have not been filed into a folder yet.
    case inbox
    /// Every document the catalog knows, by title.
    case all

    public static let recents = CatalogScope.recents(limit: 20)
}

/// One row of `documents`, as listed in the library.
public struct DocumentRow: Hashable, Identifiable, Sendable {
    public var id: DocumentID
    public var title: String
    public var kind: DocumentKind
    public var folderID: FolderID?
    public var cover: CoverStyle
    public var pageCount: Int
    public var createdAt: Date
    public var modifiedAt: Date
    public var lastOpenedAt: Date?
    public var isFavorite: Bool
    public var schemaVersion: Int
    /// The package's schema is newer than this build reads; listed read-only.
    public var needsNewerApp: Bool
    public var pendingReviewCount: Int
    /// First live page, when the catalog holds the document's pages.
    public var firstPageID: PageID?

    public init(id: DocumentID, title: String, kind: DocumentKind, folderID: FolderID?, cover: CoverStyle, pageCount: Int,
                createdAt: Date, modifiedAt: Date, lastOpenedAt: Date?, isFavorite: Bool, schemaVersion: Int,
                needsNewerApp: Bool, pendingReviewCount: Int, firstPageID: PageID?) {
        self.id = id; self.title = title; self.kind = kind; self.folderID = folderID; self.cover = cover
        self.pageCount = pageCount; self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.lastOpenedAt = lastOpenedAt
        self.isFavorite = isFavorite; self.schemaVersion = schemaVersion; self.needsNewerApp = needsNewerApp
        self.pendingReviewCount = pendingReviewCount; self.firstPageID = firstPageID
    }
}

/// One row of `pages` for a document, in page order.
public struct PageRow: Hashable, Identifiable, Sendable {
    public var id: PageID
    public var documentID: DocumentID
    public var pageIndex: Int
    public var revisionID: RevisionID
    public var isBookmarked: Bool
    public var isProblem: Bool
    public var problemTitle: String?
    public var problemStatus: ProblemStatus?
    public init(id: PageID, documentID: DocumentID, pageIndex: Int, revisionID: RevisionID, isBookmarked: Bool,
                isProblem: Bool, problemTitle: String?, problemStatus: ProblemStatus?) {
        self.id = id; self.documentID = documentID; self.pageIndex = pageIndex; self.revisionID = revisionID
        self.isBookmarked = isBookmarked; self.isProblem = isProblem; self.problemTitle = problemTitle; self.problemStatus = problemStatus
    }
}

/// A review item joined with its document and page, oldest first.
public struct ReviewQueueRow: Hashable, Identifiable, Sendable {
    public var itemID: ReviewItemID
    public var documentID: DocumentID
    public var documentTitle: String
    public var folderID: FolderID?
    public var pageID: PageID
    public var pageIndex: Int
    public var region: PageRect?
    public var prompt: String?
    /// Tape object covering the answer, if the student added one for this item.
    /// Catalogued because the queue reveals the answer without opening the page.
    public var answerTapeID: ObjectID?
    public var state: ReviewState
    public var createdAt: Date
    public var lastReviewedAt: Date?
    public var problemTitle: String?
    public var problemStatus: ProblemStatus?
    public var id: ReviewItemID { itemID }

    public init(itemID: ReviewItemID, documentID: DocumentID, documentTitle: String, folderID: FolderID?, pageID: PageID,
                pageIndex: Int, region: PageRect?, prompt: String?, answerTapeID: ObjectID?, state: ReviewState,
                createdAt: Date, lastReviewedAt: Date?, problemTitle: String?, problemStatus: ProblemStatus?) {
        self.itemID = itemID; self.documentID = documentID; self.documentTitle = documentTitle; self.folderID = folderID
        self.pageID = pageID; self.pageIndex = pageIndex; self.region = region; self.prompt = prompt
        self.answerTapeID = answerTapeID; self.state = state
        self.createdAt = createdAt; self.lastReviewedAt = lastReviewedAt; self.problemTitle = problemTitle; self.problemStatus = problemStatus
    }

    /// The catalog's projection of the item. `history` is not catalogued; load
    /// the document when the event log itself is wanted.
    public var reviewItem: ReviewItem {
        ReviewItem(id: itemID, pageID: pageID, region: region, prompt: prompt, answerTapeID: answerTapeID,
                   state: state, createdAt: createdAt, lastReviewedAt: lastReviewedAt)
    }
}

/// One full-text search hit.
public struct SearchHitRow: Hashable, Sendable {
    public var documentID: DocumentID
    public var documentTitle: String
    public var pageID: PageID
    public var pageIndex: Int
    public var revisionID: RevisionID
    public var kind: SearchRecordKind
    /// Excerpt around the match produced by FTS5 `snippet()`; matched terms are wrapped in the requested markers.
    public var snippet: String
    /// The whole indexed fragment.
    public var text: String
    public var bounds: PageRect?
    /// FTS5 bm25 score; lower is a better match within one `kind`.
    public var rank: Double

    public init(documentID: DocumentID, documentTitle: String, pageID: PageID, pageIndex: Int, revisionID: RevisionID,
                kind: SearchRecordKind, snippet: String, text: String, bounds: PageRect?, rank: Double) {
        self.documentID = documentID; self.documentTitle = documentTitle; self.pageID = pageID; self.pageIndex = pageIndex
        self.revisionID = revisionID; self.kind = kind; self.snippet = snippet; self.text = text; self.bounds = bounds; self.rank = rank
    }
}

/// Markers wrapped around matched terms in `SearchHitRow.snippet`. Defaults to none.
public struct SnippetStyle: Hashable, Sendable {
    public var highlightStart: String
    public var highlightEnd: String
    public var ellipsis: String
    /// Approximate number of tokens in the excerpt (FTS5 allows at most 64).
    public var tokenCount: Int
    public init(highlightStart: String = "", highlightEnd: String = "", ellipsis: String = "…", tokenCount: Int = 12) {
        self.highlightStart = highlightStart; self.highlightEnd = highlightEnd; self.ellipsis = ellipsis
        self.tokenCount = max(1, min(64, tokenCount))
    }
    public static let plain = SnippetStyle()
}
