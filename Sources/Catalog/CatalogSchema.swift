import Foundation

/// Schema v2 of the rebuildable catalog. The version lives in `user_version`.
/// Every table is derived from `library.json` and the document packages; the
/// only data that is not trivially re-derivable (PDF text and recognized text)
/// is keyed by page revision so it is discarded exactly when stale. A shape
/// change is therefore a version bump and a rebuild from the packages, not a
/// migration: nothing here is worth carrying across.
enum CatalogSchema {
    static let version = 2

    static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS folders(
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            parent_id TEXT,
            is_course INTEGER NOT NULL DEFAULT 0,
            color TEXT NOT NULL,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            sort_index INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS folders_parent_id ON folders(parent_id)",
        """
        CREATE TABLE IF NOT EXISTS documents(
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            kind TEXT NOT NULL,
            folder_id TEXT,
            cover_json TEXT NOT NULL,
            page_count INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            modified_at REAL NOT NULL,
            last_opened_at REAL,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            schema_version INTEGER NOT NULL,
            needs_newer_app INTEGER NOT NULL DEFAULT 0,
            pending_review_count INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS documents_folder_id ON documents(folder_id)",
        """
        CREATE TABLE IF NOT EXISTS pages(
            id TEXT PRIMARY KEY NOT NULL,
            document_id TEXT NOT NULL,
            page_index INTEGER NOT NULL,
            revision_id TEXT NOT NULL,
            is_bookmarked INTEGER NOT NULL DEFAULT 0,
            is_problem INTEGER NOT NULL DEFAULT 0,
            problem_title TEXT,
            problem_status TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS pages_document_id ON pages(document_id, page_index)",
        """
        CREATE TABLE IF NOT EXISTS review_items(
            id TEXT PRIMARY KEY NOT NULL,
            document_id TEXT NOT NULL,
            page_id TEXT NOT NULL,
            state TEXT NOT NULL,
            prompt TEXT,
            created_at REAL NOT NULL,
            last_reviewed_at REAL,
            region_json TEXT,
            answer_tape_id TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS review_items_document_id ON review_items(document_id)",
        "CREATE INDEX IF NOT EXISTS review_items_page_id ON review_items(page_id)",
        """
        CREATE TABLE IF NOT EXISTS search_records(
            id INTEGER PRIMARY KEY,
            document_id TEXT NOT NULL,
            page_id TEXT NOT NULL,
            revision_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            text TEXT NOT NULL,
            bounds_json TEXT,
            language TEXT NOT NULL,
            confidence REAL
        )
        """,
        "CREATE INDEX IF NOT EXISTS search_records_document_id ON search_records(document_id)",
        "CREATE INDEX IF NOT EXISTS search_records_page_id ON search_records(page_id, kind)",
        // External-content FTS5 table over search_records.text. Kept in sync explicitly
        // by CatalogDatabase (insert / 'delete' commands), never by triggers.
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
            text,
            content='search_records',
            content_rowid='id',
            tokenize='unicode61 remove_diacritics 2'
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS page_index_status(
            page_id TEXT PRIMARY KEY NOT NULL,
            document_id TEXT NOT NULL,
            revision_id TEXT NOT NULL,
            pdf_text_state TEXT NOT NULL,
            recognized_state TEXT NOT NULL,
            last_error TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS page_index_status_document_id ON page_index_status(document_id)",
    ]

    /// Tables whose rows `reset()` clears (the FTS index is rebuilt afterwards).
    static let contentTables = ["folders", "documents", "pages", "review_items", "search_records", "page_index_status"]

    /// Everything `install` creates, for dropping on an explicit recreate.
    static let dropStatements: [String] = [
        "DROP TABLE IF EXISTS search_fts",
        "DROP TABLE IF EXISTS page_index_status",
        "DROP TABLE IF EXISTS search_records",
        "DROP TABLE IF EXISTS review_items",
        "DROP TABLE IF EXISTS pages",
        "DROP TABLE IF EXISTS documents",
        "DROP TABLE IF EXISTS folders",
    ]

    /// Creates the schema if absent and validates `user_version`.
    /// - Throws: `CatalogError.schemaMismatch` when the file was written by
    ///   another version and `recreateOnMismatch` is false.
    static func install(in db: SQLiteDatabase, recreateOnMismatch: Bool) throws {
        let found = db.userVersion
        if found != 0 && found != version {
            guard recreateOnMismatch else { throw CatalogError.schemaMismatch(found: found, expected: version) }
            try db.transaction {
                for sql in dropStatements { try db.execute(sql) }
                try db.setUserVersion(0)
            }
        }
        try db.transaction {
            for sql in statements { try db.execute(sql) }
            try db.setUserVersion(version)
        }
    }
}
