import Foundation
import DocumentCore
import Editing

// The app-facing contract. UI code depends on these protocols and value types
// only; `LibraryService` and `DocumentSession` (Workspace module) implement
// them on top of Persistence, Catalog, Archive and Editing. Keep this file
// small and stable: it is what the SwiftUI/UIKit layers are written against.

public struct DocumentSummary: Hashable, Identifiable, Sendable {
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
    public var firstPageID: PageID?
    public var pendingReviewCount: Int
    /// True when the package's schema is newer than this build can open; shown read-only with an explanation.
    public var needsNewerApp: Bool
    public init(id: DocumentID, title: String, kind: DocumentKind, folderID: FolderID?, cover: CoverStyle, pageCount: Int,
                createdAt: Date, modifiedAt: Date, lastOpenedAt: Date?, isFavorite: Bool, firstPageID: PageID?,
                pendingReviewCount: Int = 0, needsNewerApp: Bool = false) {
        self.id = id; self.title = title; self.kind = kind; self.folderID = folderID; self.cover = cover; self.pageCount = pageCount
        self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.lastOpenedAt = lastOpenedAt; self.isFavorite = isFavorite
        self.firstPageID = firstPageID; self.pendingReviewCount = pendingReviewCount; self.needsNewerApp = needsNewerApp
    }
}

public struct FolderSummary: Hashable, Identifiable, Sendable {
    public var folder: Folder
    public var documentCount: Int
    public var subfolderCount: Int
    public var id: FolderID { folder.id }
    public init(folder: Folder, documentCount: Int, subfolderCount: Int) {
        self.folder = folder; self.documentCount = documentCount; self.subfolderCount = subfolderCount
    }
}

public enum LibraryScope: Hashable, Sendable {
    case folder(FolderID?)      // nil = library root
    case recents
    case favorites
    case inbox                  // quick notes not yet filed (folderID == nil, kind == .quickNote)
    case trash
}

public struct TrashSummary: Hashable, Identifiable, Sendable {
    public var entry: TrashEntry
    public var id: UUID { entry.id }
    public init(entry: TrashEntry) { self.entry = entry }
}

public enum ImportKind: String, Hashable, Sendable { case pdf, image, archive, auto }

public struct ImportRequest: Hashable, Sendable {
    public var sourceURL: URL
    public var kind: ImportKind
    /// True when `sourceURL` came from a document picker or share sheet and must be
    /// opened with security-scoped access before it is copied into staging.
    public var isSecurityScoped: Bool
    public init(sourceURL: URL, kind: ImportKind = .auto, isSecurityScoped: Bool = true) {
        self.sourceURL = sourceURL; self.kind = kind; self.isSecurityScoped = isSecurityScoped
    }
}

public enum ImportDestination: Hashable, Sendable {
    case newNotebook(folderID: FolderID?, title: String?)
    /// Insert imported pages into an existing notebook after `afterPageIndex` (nil = at the front, pageCount-1 = at the end).
    case insert(documentID: DocumentID, afterPageIndex: Int?)
}

public struct ImportProgress: Hashable, Sendable {
    public var completedUnits: Int
    public var totalUnits: Int
    public var message: String
    public init(completedUnits: Int, totalUnits: Int, message: String) {
        self.completedUnits = completedUnits; self.totalUnits = totalUnits; self.message = message
    }
}

public struct ImportResult: Hashable, Sendable {
    public var createdDocumentIDs: [DocumentID]
    public var insertedPageIDs: [PageID]
    public var warnings: [String]
    public init(createdDocumentIDs: [DocumentID] = [], insertedPageIDs: [PageID] = [], warnings: [String] = []) {
        self.createdDocumentIDs = createdDocumentIDs; self.insertedPageIDs = insertedPageIDs; self.warnings = warnings
    }
}

public enum RestoreMode: String, Hashable, Sendable {
    /// Every document in the backup is added as a copy (new IDs). Existing documents are untouched.
    case addCopies
    /// Documents whose ID is absent from the library are restored with their original ID; others are skipped.
    case restoreMissing
}

public struct BackupReport: Hashable, Sendable {
    public var documentCount: Int
    public var byteCount: Int
    public var archiveURL: URL
    public var validated: Bool
    public init(documentCount: Int, byteCount: Int, archiveURL: URL, validated: Bool) {
        self.documentCount = documentCount; self.byteCount = byteCount; self.archiveURL = archiveURL; self.validated = validated
    }
}

public struct RestoreReport: Hashable, Sendable {
    public var restoredDocumentIDs: [DocumentID]
    public var skippedDocumentIDs: [DocumentID]
    public var restoredFolderCount: Int
    public var warnings: [String]
    public init(restoredDocumentIDs: [DocumentID], skippedDocumentIDs: [DocumentID], restoredFolderCount: Int, warnings: [String]) {
        self.restoredDocumentIDs = restoredDocumentIDs; self.skippedDocumentIDs = skippedDocumentIDs
        self.restoredFolderCount = restoredFolderCount; self.warnings = warnings
    }
}

public enum SearchScope: Hashable, Sendable {
    case library
    case folder(FolderID)
    case document(DocumentID)
}

public struct SearchHit: Hashable, Identifiable, Sendable {
    public var documentID: DocumentID
    public var documentTitle: String
    public var pageID: PageID
    public var pageIndex: Int
    public var revisionID: RevisionID
    public var kind: SearchRecordKind
    public var snippet: String
    public var bounds: PageRect?
    public var id: String { "\(pageID)-\(kind.rawValue)-\(bounds.map { "\($0.minX),\($0.minY)" } ?? "-")-\(snippet.hashValue)" }
    public init(documentID: DocumentID, documentTitle: String, pageID: PageID, pageIndex: Int, revisionID: RevisionID,
                kind: SearchRecordKind, snippet: String, bounds: PageRect?) {
        self.documentID = documentID; self.documentTitle = documentTitle; self.pageID = pageID; self.pageIndex = pageIndex
        self.revisionID = revisionID; self.kind = kind; self.snippet = snippet; self.bounds = bounds
    }
}

public struct SearchResults: Hashable, Sendable {
    public var query: String
    public var hits: [SearchHit]
    /// Pages in scope whose PDF text or recognition has not been indexed yet; lets the UI say "not yet indexed".
    public var notYetIndexedPageCount: Int
    public var failedPageCount: Int
    public var isIndexingInProgress: Bool
    public init(query: String, hits: [SearchHit], notYetIndexedPageCount: Int, failedPageCount: Int, isIndexingInProgress: Bool) {
        self.query = query; self.hits = hits; self.notYetIndexedPageCount = notYetIndexedPageCount
        self.failedPageCount = failedPageCount; self.isIndexingInProgress = isIndexingInProgress
    }
}

public struct ReviewQueueEntry: Hashable, Identifiable, Sendable {
    public var item: ReviewItem
    public var documentID: DocumentID
    public var documentTitle: String
    public var courseID: FolderID?
    public var courseName: String?
    public var pageIndex: Int
    public var problemTitle: String?
    public var problemStatus: ProblemStatus?
    public var id: ReviewItemID { item.id }
    public init(item: ReviewItem, documentID: DocumentID, documentTitle: String, courseID: FolderID?, courseName: String?,
                pageIndex: Int, problemTitle: String?, problemStatus: ProblemStatus?) {
        self.item = item; self.documentID = documentID; self.documentTitle = documentTitle; self.courseID = courseID
        self.courseName = courseName; self.pageIndex = pageIndex; self.problemTitle = problemTitle; self.problemStatus = problemStatus
    }
}

public struct StorageReport: Hashable, Sendable {
    public var documentBytes: Int
    public var trashBytes: Int
    public var catalogBytes: Int
    public var previewBytes: Int
    public var availableBytes: Int?
    public init(documentBytes: Int, trashBytes: Int, catalogBytes: Int, previewBytes: Int, availableBytes: Int?) {
        self.documentBytes = documentBytes; self.trashBytes = trashBytes; self.catalogBytes = catalogBytes
        self.previewBytes = previewBytes; self.availableBytes = availableBytes
    }
}

public enum WorkspaceError: Error, Equatable {
    case documentNotFound(DocumentID)
    case folderNotFound(FolderID)
    case documentNeedsNewerApp(DocumentID, schemaVersion: Int)
    case documentAlreadyOpen(DocumentID)
    case importFailed(String)
    case unsupportedFile(String)
    case cancelled
    case storage(String)
    case archive(String)
    case catalogUnavailable(String)
}

/// Library-wide operations. Implemented by `LibraryService` (an actor).
public protocol LibraryServicing: AnyObject, Sendable {
    func manifest() async throws -> LibraryManifest
    func documents(in scope: LibraryScope) async throws -> [DocumentSummary]
    func document(_ id: DocumentID) async throws -> DocumentSummary
    func folders(in parent: FolderID?) async throws -> [FolderSummary]
    func trashEntries() async throws -> [TrashSummary]

    func createFolder(name: String, parentID: FolderID?, isCourse: Bool) async throws -> Folder
    func updateFolder(_ folder: Folder) async throws
    /// Moves the folder and everything inside it to the trash.
    func deleteFolder(_ id: FolderID) async throws

    func createNotebook(title: String, folderID: FolderID?, template: PaperTemplate, pageSize: PageSize, cover: CoverStyle, pageCount: Int) async throws -> DocumentID
    func createQuickNote(template: PaperTemplate) async throws -> DocumentID
    func rename(_ id: DocumentID, to title: String) async throws
    func move(_ id: DocumentID, toFolder folderID: FolderID?) async throws
    func duplicate(_ id: DocumentID) async throws -> DocumentID
    func setFavorite(_ id: DocumentID, _ isFavorite: Bool) async throws
    func setCover(_ id: DocumentID, _ cover: CoverStyle) async throws
    /// Moves the document to the recoverable trash.
    func delete(_ id: DocumentID) async throws
    func restore(trashEntryID: UUID) async throws
    func purge(trashEntryID: UUID) async throws
    func emptyTrash() async throws

    /// Opens (or returns the already open) editing session. Sessions are main-actor objects.
    func openSession(_ id: DocumentID) async throws -> any DocumentSessioning
    func closeSession(_ id: DocumentID) async

    func importFiles(_ requests: [ImportRequest], destination: ImportDestination,
                     progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportResult
    func exportArchive(documentIDs: [DocumentID], to url: URL, progress: @Sendable @escaping (ImportProgress) -> Void) async throws
    func backupLibrary(to url: URL, progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> BackupReport
    func restoreLibrary(from url: URL, mode: RestoreMode, progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> RestoreReport

    func search(_ query: String, scope: SearchScope) async throws -> SearchResults
    /// Pending review items for one course (folder subtree) or, with nil, every course and unfiled notebook.
    func reviewQueue(courseID: FolderID?) async throws -> [ReviewQueueEntry]
    func markReviewed(_ itemID: ReviewItemID, in documentID: DocumentID) async throws
    func reopenReview(_ itemID: ReviewItemID, in documentID: DocumentID) async throws

    func rebuildCatalog(progress: @Sendable @escaping (ImportProgress) -> Void) async throws
    func storageReport() async throws -> StorageReport
}

/// One open document: the editor, save status and per-document services.
/// Main-actor bound because the editor is driven by UI events. Implemented in
/// `DocumentSession.swift` (Workspace module).
@MainActor
public protocol DocumentSessioning: AnyObject {
    var documentID: DocumentID { get }
    var editor: DocumentEditor { get }
    var saveStatus: SaveStatus { get }
    /// Called on the main actor whenever `saveStatus` changes.
    var onSaveStatusChange: ((SaveStatus) -> Void)? { get set }
    /// Called after every applied command with the change set, so views refresh only what changed.
    var onChange: ((ChangeSet) -> Void)? { get set }

    /// Applies a command through the editor, records it for undo, schedules a save.
    func apply(_ command: EditCommand) throws
    func undo()
    func redo()
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    /// Groups several `apply` calls into one undo step (e.g. a lasso move of ink + objects).
    func performGrouped(_ name: String, _ body: () throws -> Void) rethrows

    /// Registers bytes for a new asset (image or ink blob) referenced by a subsequent command.
    func addAsset(_ asset: PendingAsset)
    /// Data for an asset already committed or pending. nil when unknown.
    func assetData(_ id: AssetID) async throws -> Data?
    /// File URL of a committed asset (for PDFKit/ImageIO). nil for pending, uncommitted assets.
    func assetURL(_ id: AssetID) async -> URL?

    /// Commits pending changes now; returns after the durable commit or throws.
    func flush() async throws
    /// Flushes and releases the session.
    func close() async

    /// Text found on a page (typed, PDF, recognized) for the search index; called by the app's recognizers.
    func recordSearchRecords(_ records: [SearchRecord], for pageID: PageID, kind: SearchRecordKind, state: IndexingState) async
    func indexStatus(for pageID: PageID) async -> PageIndexStatus?
    /// Pages whose current revision has not been recognized yet, oldest first.
    func pagesNeedingRecognition() async -> [PageID]
}
