import Foundation
import DocumentCore

/// The rebuildable catalog: library listing, review queue and full-text
/// search over one SQLite file (or memory). Document packages stay the source
/// of truth; everything here is derived from `LibraryManifest` and
/// `DocumentSnapshot` values plus the search records the app's recognizers
/// report, which are keyed by page revision and dropped when a page changes.
public actor CatalogDatabase {
    public enum Location: Hashable, Sendable {
        case file(URL)
        case memory
    }

    public nonisolated let location: Location
    private let db: SQLiteDatabase
    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private let jsonDecoder = JSONDecoder()

    private init(db: SQLiteDatabase, location: Location) {
        self.db = db
        self.location = location
    }

    // MARK: Opening

    /// Opens or creates the catalog file at `url` (parent directory is created).
    /// - Parameter recreateOnSchemaMismatch: when true a file written by
    ///   another schema version is dropped and recreated instead of throwing
    ///   `CatalogError.schemaMismatch`.
    public static func open(at url: URL, recreateOnSchemaMismatch: Bool = false) throws -> CatalogDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: url.path)
        do { try CatalogSchema.install(in: db, recreateOnMismatch: recreateOnSchemaMismatch) } catch { db.close(); throw error }
        return CatalogDatabase(db: db, location: .file(url))
    }

    /// A private in-memory catalog with the same schema and behaviour.
    public static func inMemory() throws -> CatalogDatabase {
        let db = try SQLiteDatabase(path: SQLiteDatabase.memoryPath)
        do { try CatalogSchema.install(in: db, recreateOnMismatch: true) } catch { db.close(); throw error }
        return CatalogDatabase(db: db, location: .memory)
    }

    public static let schemaVersion = CatalogSchema.version

    public func close() { db.close() }
    public var isOpen: Bool { db.isOpen }

    /// Removes every row (folders, documents, pages, review items, search records, index states).
    public func reset() throws {
        try db.transaction {
            for table in CatalogSchema.contentTables { try db.execute("DELETE FROM \(table)") }
            try db.execute("INSERT INTO search_fts(search_fts) VALUES('rebuild')")
        }
    }

    /// `PRAGMA integrity_check` complaints; empty when the database is sound.
    public func integrityCheck() throws -> [String] { try db.integrityCheck() }

    /// Bytes used on disk (database + WAL + SHM) or, for `.memory`, by the page cache.
    public func storageSizeInBytes() throws -> Int { try db.storageSizeInBytes() }

    /// Runs a WAL checkpoint so the main file holds every committed row.
    public func checkpoint() throws { try db.checkpoint() }

    // MARK: Folders

    /// Replaces the folder table with the manifest's folders and drops every
    /// document the manifest lists in the trash.
    public func upsertFolders(_ manifest: LibraryManifest) throws {
        try db.transaction {
            try db.run("DELETE FROM folders")
            for folder in manifest.folders {
                try db.run("""
                    INSERT INTO folders(id, name, parent_id, is_course, color, is_favorite, created_at, sort_index)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.init(folder.id), .init(folder.name), .init(folder.parentID), .init(folder.isCourse),
                          .init(folder.color.rawValue), .init(folder.isFavorite), .init(folder.createdAt), .init(folder.sortIndex)])
            }
            for entry in manifest.trash {
                switch entry.item {
                case .document(let id): try removeDocumentRows(id)
                case .folder(_, let ids): for id in ids { try removeDocumentRows(id) }
                }
            }
        }
    }

    /// Folders ordered by sort index then name.
    public func folders() throws -> [Folder] {
        try db.query("SELECT id, name, parent_id, is_course, color, is_favorite, created_at, sort_index FROM folders ORDER BY sort_index, name COLLATE NOCASE, id") { s in
            guard let id: FolderID = s.identifier(0) else { throw CatalogError.encoding("folder id") }
            return Folder(id: id, name: s.string(1), parentID: s.optionalString(2).flatMap(FolderID.init(uuidString:)),
                          isCourse: s.bool(3), color: CoverStyle.Palette(rawValue: s.string(4)) ?? .slate,
                          isFavorite: s.bool(5), createdAt: s.date(6), sortIndex: s.int(7))
        }
    }

    // MARK: Documents

    /// Catalogues a whole document: header row, pages, review items, title and
    /// typed-text search records. PDF-text and recognized records of pages
    /// whose revision changed (or that were deleted) are dropped and those
    /// pages return to `notIndexed`; unchanged pages keep their records and state.
    public func upsertDocument(_ snapshot: DocumentSnapshot, needsNewerApp: Bool = false) throws {
        try db.transaction {
            let document = snapshot.document
            let pages = snapshot.orderedPages
            let liveIDs = Set(pages.map(\.id))
            let pending = document.reviewItems.filter { $0.state == .pending && liveIDs.contains($0.pageID) }.count
            try writeDocumentRow(document, pageCount: pages.count, needsNewerApp: needsNewerApp, pendingReviewCount: pending)

            let docID = SQLiteValue(document.id)
            try db.run("DELETE FROM pages WHERE document_id = ?", [docID])
            for (index, page) in pages.enumerated() {
                try db.run("""
                    INSERT INTO pages(id, document_id, page_index, revision_id, is_bookmarked, is_problem, problem_title, problem_status)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.init(page.id), docID, .init(index), .init(page.revisionID), .init(page.isBookmarked),
                          .init(page.problem != nil), .init(page.problem?.title), .init(page.problem?.status.rawValue)])
            }

            try db.run("DELETE FROM review_items WHERE document_id = ?", [docID])
            for item in document.reviewItems where liveIDs.contains(item.pageID) {
                try db.run("""
                    INSERT INTO review_items(id, document_id, page_id, state, prompt, created_at, last_reviewed_at, region_json)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.init(item.id), docID, .init(item.pageID), .init(item.state.rawValue), .init(item.prompt),
                          .init(item.createdAt), .init(item.lastReviewedAt), .init(try encodeJSON(item.region))])
            }

            // Synchronously indexed records are rebuilt from the snapshot every time.
            try deleteSearchRecords(matching: "SELECT id, text FROM search_records WHERE document_id = ?1 AND kind IN ('title', 'typed')", [docID])
            // Derived records survive only while the page's revision is unchanged.
            try deleteSearchRecords(matching: """
                SELECT r.id, r.text FROM search_records r
                LEFT JOIN pages p ON p.id = r.page_id
                WHERE r.document_id = ?1 AND r.kind IN ('pdfText', 'recognized') AND (p.id IS NULL OR p.revision_id != r.revision_id)
                """, [docID])
            for record in synchronousRecords(for: snapshot) { try insertSearchRecord(record) }

            try db.run("DELETE FROM page_index_status WHERE document_id = ?1 AND page_id NOT IN (SELECT id FROM pages WHERE document_id = ?1)", [docID])
            for page in pages {
                let current = try db.query("SELECT revision_id FROM page_index_status WHERE page_id = ?", [.init(page.id)]) { $0.string(0) }.first
                if current == page.revisionID.description { continue }
                try db.run("""
                    INSERT OR REPLACE INTO page_index_status(page_id, document_id, revision_id, pdf_text_state, recognized_state, last_error)
                    VALUES(?, ?, ?, ?, ?, NULL)
                    """, [.init(page.id), docID, .init(page.revisionID),
                          .init(CatalogDatabase.initialPDFTextState(for: page).rawValue), .init(IndexingState.notIndexed.rawValue)])
            }
        }
    }

    /// Updates only the `documents` row (title, folder, cover, favourite,
    /// timestamps, page count) for cheap library operations such as rename or
    /// move. Pages, review items and derived records are untouched; the title
    /// search record is refreshed when the document's pages are catalogued.
    public func upsertDocumentHeader(_ document: Document, pageCount: Int, needsNewerApp: Bool = false) throws {
        try db.transaction {
            let live = Set(document.pageIDs)
            let pending = document.reviewItems.filter { $0.state == .pending && live.contains($0.pageID) }.count
            try writeDocumentRow(document, pageCount: pageCount, needsNewerApp: needsNewerApp, pendingReviewCount: pending)
            let docID = SQLiteValue(document.id)
            try deleteSearchRecords(matching: "SELECT id, text FROM search_records WHERE document_id = ?1 AND kind = 'title'", [docID])
            let first = try db.query("SELECT id, revision_id FROM pages WHERE document_id = ? ORDER BY page_index LIMIT 1", [docID]) {
                ($0.identifier(0, as: PageID.self), $0.identifier(1, as: RevisionID.self))
            }.first
            if let first, let pageID = first.0, let revisionID = first.1, let record = CatalogDatabase.titleRecord(document, pageID: pageID, revisionID: revisionID) {
                try insertSearchRecord(record)
            }
        }
    }

    /// Removes the document and everything derived from it.
    public func removeDocument(_ id: DocumentID) throws {
        try db.transaction { try removeDocumentRows(id) }
    }

    public func document(_ id: DocumentID) throws -> DocumentRow? {
        try db.query(CatalogDatabase.documentSelect + " WHERE d.id = ?", [.init(id)], decodeDocumentRow).first
    }

    /// Documents in a scope. Folder, favourites and `.all` listings are sorted
    /// by title; recents and the inbox newest first.
    public func documents(in scope: CatalogScope) throws -> [DocumentRow] {
        let base = CatalogDatabase.documentSelect
        switch scope {
        case .folder(let folderID?):
            return try db.query(base + " WHERE d.folder_id = ? ORDER BY d.title COLLATE NOCASE, d.id", [.init(folderID)], decodeDocumentRow)
        case .folder(nil):
            return try db.query(base + " WHERE d.folder_id IS NULL AND d.kind != 'quickNote' ORDER BY d.title COLLATE NOCASE, d.id", [], decodeDocumentRow)
        case .recents(let limit):
            return try db.query(base + " ORDER BY COALESCE(d.last_opened_at, d.modified_at) DESC, d.title COLLATE NOCASE, d.id LIMIT ?", [.init(max(0, limit))], decodeDocumentRow)
        case .favorites:
            return try db.query(base + " WHERE d.is_favorite = 1 ORDER BY d.title COLLATE NOCASE, d.id", [], decodeDocumentRow)
        case .inbox:
            return try db.query(base + " WHERE d.folder_id IS NULL AND d.kind = 'quickNote' ORDER BY d.modified_at DESC, d.title COLLATE NOCASE, d.id", [], decodeDocumentRow)
        case .all:
            return try db.query(base + " ORDER BY d.title COLLATE NOCASE, d.id", [], decodeDocumentRow)
        }
    }

    /// Number of documents filed directly in `folderID` (nil = unfiled notebooks, excluding inbox quick notes).
    public func documentCount(inFolder folderID: FolderID?) throws -> Int {
        let value: SQLiteValue
        if let folderID {
            value = try db.scalar("SELECT COUNT(*) FROM documents WHERE folder_id = ?", [.init(folderID)])
        } else {
            value = try db.scalar("SELECT COUNT(*) FROM documents WHERE folder_id IS NULL AND kind != 'quickNote'")
        }
        if case .integer(let n) = value { return Int(n) }
        return 0
    }

    /// Catalogued pages of a document in page order.
    public func pages(in documentID: DocumentID) throws -> [PageRow] {
        try db.query("""
            SELECT id, document_id, page_index, revision_id, is_bookmarked, is_problem, problem_title, problem_status
            FROM pages WHERE document_id = ? ORDER BY page_index
            """, [.init(documentID)]) { s in
            guard let id: PageID = s.identifier(0), let doc: DocumentID = s.identifier(1), let rev: RevisionID = s.identifier(3) else {
                throw CatalogError.encoding("page row")
            }
            return PageRow(id: id, documentID: doc, pageIndex: s.int(2), revisionID: rev, isBookmarked: s.bool(4), isProblem: s.bool(5),
                           problemTitle: s.optionalString(6), problemStatus: s.optionalString(7).flatMap(ProblemStatus.init(rawValue:)))
        }
    }

    // MARK: Review queue

    /// Pending review items, oldest first.
    /// - Parameters:
    ///   - folderIDs: only documents filed in these folders (pass a course
    ///     subtree from `LibraryManifest.subtree(of:)`); nil means every filed document.
    ///   - includeUnfiled: also documents that are not in any folder.
    public func reviewQueue(folderIDs: Set<FolderID>?, includeUnfiled: Bool) throws -> [ReviewQueueRow] {
        try db.query("""
            SELECT ri.id, ri.document_id, d.title, d.folder_id, ri.page_id, p.page_index, ri.region_json, ri.prompt, ri.state,
                   ri.created_at, ri.last_reviewed_at, p.problem_title, p.problem_status
            FROM review_items ri
            JOIN documents d ON d.id = ri.document_id
            JOIN pages p ON p.id = ri.page_id
            WHERE ri.state = 'pending'
              AND ((?1 = 0 AND d.folder_id IS NOT NULL)
                   OR d.folder_id IN (SELECT value FROM json_each(?2))
                   OR (?3 = 1 AND d.folder_id IS NULL))
            ORDER BY ri.created_at, d.title COLLATE NOCASE, p.page_index, ri.id
            """, [.init(folderIDs != nil), .init(CatalogDatabase.jsonArray(folderIDs ?? [])), .init(includeUnfiled)]) { s in
            guard let itemID: ReviewItemID = s.identifier(0), let docID: DocumentID = s.identifier(1), let pageID: PageID = s.identifier(4) else {
                throw CatalogError.encoding("review item row")
            }
            return ReviewQueueRow(
                itemID: itemID, documentID: docID, documentTitle: s.string(2),
                folderID: s.optionalString(3).flatMap(FolderID.init(uuidString:)), pageID: pageID, pageIndex: s.int(5),
                region: try decodeJSON(PageRect.self, s.optionalString(6)), prompt: s.optionalString(7),
                state: ReviewState(rawValue: s.string(8)) ?? .pending, createdAt: s.date(9), lastReviewedAt: s.optionalDate(10),
                problemTitle: s.optionalString(11), problemStatus: s.optionalString(12).flatMap(ProblemStatus.init(rawValue:)))
        }
    }

    // MARK: Search

    /// Full-text search. Hits are ranked by kind (title, typed, PDF text,
    /// recognized) and then by FTS5 bm25 within each kind. An empty query
    /// returns no hits. Use `notYetIndexedCount` to tell "no matches" from
    /// "not indexed yet".
    public func search(_ query: String, documentIDs: Set<DocumentID>? = nil, limit: Int = 200,
                       snippet style: SnippetStyle = .plain) throws -> [SearchHitRow] {
        guard let match = FTSQuery.sanitize(query) else { return [] }
        let sql = """
            SELECT r.document_id, d.title, r.page_id, COALESCE(p.page_index, 0), r.revision_id, r.kind,
                   snippet(search_fts, 0, ?1, ?2, ?3, \(style.tokenCount)), r.text, r.bounds_json, bm25(search_fts) AS score
            FROM search_fts
            JOIN search_records r ON r.id = search_fts.rowid
            JOIN documents d ON d.id = r.document_id
            LEFT JOIN pages p ON p.id = r.page_id
            WHERE search_fts MATCH ?4
              AND (?5 = 0 OR r.document_id IN (SELECT value FROM json_each(?6)))
            ORDER BY CASE r.kind WHEN 'title' THEN 0 WHEN 'typed' THEN 1 WHEN 'pdfText' THEN 2 ELSE 3 END,
                     score, d.title COLLATE NOCASE, r.document_id, COALESCE(p.page_index, 0), r.id
            LIMIT ?7
            """
        return try db.query(sql, [.init(style.highlightStart), .init(style.highlightEnd), .init(style.ellipsis), .init(match),
                                  .init(documentIDs != nil), .init(CatalogDatabase.jsonArray(documentIDs ?? [])), .init(max(0, limit))]) { s in
            guard let docID: DocumentID = s.identifier(0), let pageID: PageID = s.identifier(2), let rev: RevisionID = s.identifier(4),
                  let kind = SearchRecordKind(rawValue: s.string(5)) else { throw CatalogError.encoding("search hit row") }
            return SearchHitRow(documentID: docID, documentTitle: s.string(1), pageID: pageID, pageIndex: s.int(3), revisionID: rev,
                                kind: kind, snippet: s.string(6), text: s.string(7),
                                bounds: try decodeJSON(PageRect.self, s.optionalString(8)), rank: s.double(9))
        }
    }

    /// Pages (in scope) whose PDF text or recognition is still `notIndexed` or `queued`.
    public func notYetIndexedCount(documentIDs: Set<DocumentID>? = nil) throws -> Int {
        try countIndexStates(documentIDs: documentIDs, states: [.notIndexed, .queued])
    }

    /// Pages (in scope) whose PDF text extraction or recognition failed.
    public func failedCount(documentIDs: Set<DocumentID>? = nil) throws -> Int {
        try countIndexStates(documentIDs: documentIDs, states: [.failed])
    }

    /// Replaces the records of `kind` for the page's *current* revision and
    /// records the resulting state. Records carrying another revision are
    /// ignored (they describe content the student has since changed).
    /// For `.typed` and `.title` the state is not tracked and `state` is ignored.
    public func setSearchRecords(_ records: [SearchRecord], pageID: PageID, kind: SearchRecordKind,
                                 state: IndexingState, error: String? = nil) throws {
        try db.transaction {
            let page = try db.query("SELECT document_id, revision_id FROM pages WHERE id = ?", [.init(pageID)]) {
                ($0.identifier(0, as: DocumentID.self), $0.identifier(1, as: RevisionID.self))
            }.first
            guard let page, let documentID = page.0, let revisionID = page.1 else { throw CatalogError.pageNotFound(pageID) }
            try deleteSearchRecords(matching: "SELECT id, text FROM search_records WHERE page_id = ?1 AND kind = ?2", [.init(pageID), .init(kind.rawValue)])
            for record in records where record.revisionID == revisionID && record.kind == kind && record.pageID == pageID {
                var stored = record
                stored.documentID = documentID
                try insertSearchRecord(stored)
            }
            let column: String
            switch kind {
            case .pdfText: column = "pdf_text_state"
            case .recognized: column = "recognized_state"
            case .title, .typed: return
            }
            try db.run("""
                INSERT INTO page_index_status(page_id, document_id, revision_id, \(column), pdf_text_state, recognized_state, last_error)
                VALUES(?1, ?2, ?3, ?4, 'notIndexed', 'notIndexed', ?5)
                ON CONFLICT(page_id) DO UPDATE SET revision_id = ?3, \(column) = ?4, last_error = ?5
                """, [.init(pageID), .init(documentID), .init(revisionID), .init(state.rawValue), .init(error)])
        }
    }

    public func indexStatus(pageID: PageID) throws -> PageIndexStatus? {
        try db.query("SELECT page_id, revision_id, pdf_text_state, recognized_state, last_error FROM page_index_status WHERE page_id = ?", [.init(pageID)]) { s in
            guard let id: PageID = s.identifier(0), let rev: RevisionID = s.identifier(1) else { throw CatalogError.encoding("index status row") }
            return PageIndexStatus(pageID: id, revisionID: rev,
                                   pdfText: IndexingState(rawValue: s.string(2)) ?? .notIndexed,
                                   recognized: IndexingState(rawValue: s.string(3)) ?? .notIndexed,
                                   lastError: s.optionalString(4))
        }.first
    }

    /// Live pages whose current revision has not been recognized, in the order
    /// they became unrecognized (a re-edited page moves to the back).
    public func pagesNeedingRecognition(documentID: DocumentID) throws -> [PageID] {
        try db.query("""
            SELECT s.page_id FROM page_index_status s
            JOIN pages p ON p.id = s.page_id
            WHERE s.document_id = ? AND s.recognized_state = 'notIndexed'
            ORDER BY s.rowid
            """, [.init(documentID)]) { s in
            guard let id: PageID = s.identifier(0) else { throw CatalogError.encoding("page id") }
            return id
        }
    }

    /// Discards everything and catalogues the library from scratch in one
    /// transaction; nothing changes if any snapshot fails.
    public func rebuild(manifest: LibraryManifest, snapshots: [DocumentSnapshot], needsNewerApp: Set<DocumentID> = []) throws {
        try db.transaction {
            try reset()
            try upsertFolders(manifest)
            for snapshot in snapshots {
                try upsertDocument(snapshot, needsNewerApp: needsNewerApp.contains(snapshot.document.id))
            }
        }
    }

    // MARK: - Private helpers

    private static let documentSelect = """
        SELECT d.id, d.title, d.kind, d.folder_id, d.cover_json, d.page_count, d.created_at, d.modified_at, d.last_opened_at,
               d.is_favorite, d.schema_version, d.needs_newer_app, d.pending_review_count,
               (SELECT p.id FROM pages p WHERE p.document_id = d.id ORDER BY p.page_index LIMIT 1)
        FROM documents d
        """

    private func decodeDocumentRow(_ s: SQLiteStatement) throws -> DocumentRow {
        guard let id: DocumentID = s.identifier(0) else { throw CatalogError.encoding("document id") }
        return DocumentRow(
            id: id, title: s.string(1), kind: DocumentKind(rawValue: s.string(2)) ?? .notebook,
            folderID: s.optionalString(3).flatMap(FolderID.init(uuidString:)),
            cover: try decodeJSON(CoverStyle.self, s.optionalString(4)) ?? .default,
            pageCount: s.int(5), createdAt: s.date(6), modifiedAt: s.date(7), lastOpenedAt: s.optionalDate(8),
            isFavorite: s.bool(9), schemaVersion: s.int(10), needsNewerApp: s.bool(11), pendingReviewCount: s.int(12),
            firstPageID: s.optionalString(13).flatMap(PageID.init(uuidString:)))
    }

    private func writeDocumentRow(_ document: Document, pageCount: Int, needsNewerApp: Bool, pendingReviewCount: Int) throws {
        try db.run("""
            INSERT INTO documents(id, title, kind, folder_id, cover_json, page_count, created_at, modified_at, last_opened_at,
                                  is_favorite, schema_version, needs_newer_app, pending_review_count)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
            ON CONFLICT(id) DO UPDATE SET title = ?2, kind = ?3, folder_id = ?4, cover_json = ?5, page_count = ?6, created_at = ?7,
                modified_at = ?8, last_opened_at = ?9, is_favorite = ?10, schema_version = ?11, needs_newer_app = ?12, pending_review_count = ?13
            """, [.init(document.id), .init(document.title), .init(document.kind.rawValue), .init(document.folderID),
                  .init(try encodeJSON(document.cover) ?? "{}"), .init(pageCount), .init(document.createdAt), .init(document.modifiedAt),
                  .init(document.lastOpenedAt), .init(document.isFavorite), .init(document.schemaVersion), .init(needsNewerApp),
                  .init(pendingReviewCount)])
    }

    private func removeDocumentRows(_ id: DocumentID) throws {
        let docID = SQLiteValue(id)
        try deleteSearchRecords(matching: "SELECT id, text FROM search_records WHERE document_id = ?1", [docID])
        try db.run("DELETE FROM page_index_status WHERE document_id = ?", [docID])
        try db.run("DELETE FROM review_items WHERE document_id = ?", [docID])
        try db.run("DELETE FROM pages WHERE document_id = ?", [docID])
        try db.run("DELETE FROM documents WHERE id = ?", [docID])
    }

    /// Deletes the search records selected by `selectSQL` (which must yield
    /// `id, text`), keeping the external-content FTS index in step.
    private func deleteSearchRecords(matching selectSQL: String, _ bindings: [SQLiteValue]) throws {
        let rows = try db.query(selectSQL, bindings) { ($0.int64(0), $0.string(1)) }
        for (id, text) in rows {
            try db.run("INSERT INTO search_fts(search_fts, rowid, text) VALUES('delete', ?, ?)", [.integer(id), .init(text)])
            try db.run("DELETE FROM search_records WHERE id = ?", [.integer(id)])
        }
    }

    private func insertSearchRecord(_ record: SearchRecord) throws {
        try db.run("""
            INSERT INTO search_records(document_id, page_id, revision_id, kind, text, bounds_json, language, confidence)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """, [.init(record.documentID), .init(record.pageID), .init(record.revisionID), .init(record.kind.rawValue), .init(record.text),
                  .init(try encodeJSON(record.bounds)), .init(record.language), .init(record.confidence)])
        try db.run("INSERT INTO search_fts(rowid, text) VALUES(?, ?)", [.integer(db.lastInsertRowID), .init(record.text)])
    }

    private func countIndexStates(documentIDs: Set<DocumentID>?, states: [IndexingState]) throws -> Int {
        let list = CatalogDatabase.jsonArray(states.map(\.rawValue))
        let value = try db.scalar("""
            SELECT COUNT(*) FROM page_index_status s
            WHERE (?1 = 0 OR s.document_id IN (SELECT value FROM json_each(?2)))
              AND (s.pdf_text_state IN (SELECT value FROM json_each(?3)) OR s.recognized_state IN (SELECT value FROM json_each(?3)))
            """, [.init(documentIDs != nil), .init(CatalogDatabase.jsonArray(documentIDs ?? [])), .init(list)])
        if case .integer(let n) = value { return Int(n) }
        return 0
    }

    /// Title and typed-text records derived from the snapshot alone.
    private func synchronousRecords(for snapshot: DocumentSnapshot) -> [SearchRecord] {
        let document = snapshot.document
        var records: [SearchRecord] = []
        let pages = snapshot.orderedPages
        if let first = pages.first, let title = CatalogDatabase.titleRecord(document, pageID: first.id, revisionID: first.revisionID) {
            records.append(title)
        }
        for page in pages {
            func typed(_ text: String?, bounds: PageRect?) {
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                records.append(SearchRecord(documentID: document.id, pageID: page.id, revisionID: page.revisionID, kind: .typed,
                                            text: text, bounds: bounds, language: document.language))
            }
            for object in page.objects {
                switch object.content {
                case .text(let content): typed(content.text, bounds: object.bounds)
                case .tape(let tape): typed(tape.label, bounds: object.bounds)
                case .image, .shape: break
                }
            }
            if let problem = page.problem {
                typed(problem.title, bounds: nil)
                typed(problem.sourceReference, bounds: nil)
                typed(problem.given, bounds: nil)
                typed(problem.find, bounds: nil)
            }
        }
        return records
    }

    private static func titleRecord(_ document: Document, pageID: PageID, revisionID: RevisionID) -> SearchRecord? {
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return SearchRecord(documentID: document.id, pageID: pageID, revisionID: revisionID, kind: .title,
                            text: document.title, bounds: nil, language: document.language)
    }

    /// PDF text only exists for PDF-backed pages; template and image pages never wait for it.
    private static func initialPDFTextState(for page: Page) -> IndexingState {
        if case .pdf = page.background { return .notIndexed }
        return .notApplicable
    }

    private static func jsonArray<ID: EntityIdentifier>(_ ids: Set<ID>) -> String {
        jsonArray(ids.map(\.description).sorted())
    }

    private static func jsonArray(_ strings: [String]) -> String {
        "[" + strings.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: ",") + "]"
    }

    private func encodeJSON<T: Encodable>(_ value: T?) throws -> String? {
        guard let value else { return nil }
        do { return String(decoding: try jsonEncoder.encode(value), as: UTF8.self) }
        catch { throw CatalogError.encoding(String(describing: error)) }
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String?) throws -> T? {
        guard let json, !json.isEmpty else { return nil }
        do { return try jsonDecoder.decode(type, from: Data(json.utf8)) }
        catch { throw CatalogError.encoding(String(describing: error)) }
    }
}
