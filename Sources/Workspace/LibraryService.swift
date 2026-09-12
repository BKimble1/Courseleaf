import Foundation
import DocumentCore
import Editing
import Persistence
import Archive
import Catalog

/// The app-facing library (docs/ARCHITECTURE.md sections 2, 7 and 9). It
/// composes `Persistence.LibraryStore` (packages are the truth),
/// `Catalog.CatalogDatabase` (a rebuildable index at `Catalog/catalog.sqlite`),
/// the archive writers/readers, and one `DocumentSession` per open document.
///
/// Opening (lazily on first use, or explicitly with `open()`): the library
/// layout is created, `Staging/` is cleared, the catalog is opened (rebuilt
/// from the packages when missing, damaged or of another schema) and
/// reconciled with what is on disk. If the catalog cannot be opened at all,
/// documents stay usable and only `search` reports `catalogUnavailable`.
public actor LibraryService: LibraryServicing {
    public nonisolated let rootURL: URL
    public nonisolated let store: LibraryStore
    public nonisolated let pdfInspector: any PDFInspecting
    public nonisolated let imageInspector: any ImageInspecting
    public nonisolated let clock: any Clock
    public nonisolated let fileSystem: any FileSystem
    /// Recorded in every archive this library writes.
    public var producer = "Courseleaf 1.0 (0)"

    private var catalog: CatalogDatabase?
    private var catalogFailure: String?
    private var isOpen = false
    private var sessions: [DocumentID: DocumentSession] = [:]
    private var saveDebounce: TimeInterval = 0.3
    private var saveMaxDelay: TimeInterval = 1.0
    private var saveSleeper: any Sleeper = TaskSleeper()

    public init(rootURL: URL, pdfInspector: any PDFInspecting, imageInspector: any ImageInspecting, clock: any Clock) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileSystem = LocalFileSystem()
        self.store = LibraryStore(rootURL: rootURL, fileSystem: fileSystem, clock: clock)
        self.pdfInspector = pdfInspector
        self.imageInspector = imageInspector
        self.clock = clock
    }

    public nonisolated var catalogFileURL: URL { store.catalogURL.appendingPathComponent("catalog.sqlite") }

    /// Save coalescing used by sessions opened afterwards (tests inject a `ManualSleeper`).
    public func configureSaving(debounce: TimeInterval = 0.3, maxDelay: TimeInterval = 1.0, sleeper: any Sleeper = TaskSleeper()) {
        saveDebounce = debounce; saveMaxDelay = maxDelay; saveSleeper = sleeper
    }

    /// Why search is unavailable, when the catalog could not be opened or rebuilt.
    public var catalogUnavailableReason: String? { catalogFailure }
    public var isCatalogAvailable: Bool { catalog != nil }
    public var openSessionIDs: [DocumentID] { sessions.keys.sorted() }

    // MARK: - Opening

    public func open() async throws {
        if isOpen { return }
        do { _ = try await store.open() } catch { throw translate(error) }
        await openCatalog(forceRebuild: false)
        isOpen = true
    }

    /// Flushes and closes every session and the catalog.
    public func close() async {
        for id in sessions.keys.sorted() { await closeSession(id) }
        if let catalog { await catalog.close() }
        catalog = nil
        isOpen = false
    }

    private func ensureOpen() async throws { if !isOpen { try await open() } }

    private func openCatalog(forceRebuild: Bool, progress: (@Sendable (ImportProgress) -> Void)? = nil) async {
        if let catalog { await catalog.close() }
        catalog = nil
        catalogFailure = nil
        var db: CatalogDatabase?
        do { db = try CatalogDatabase.open(at: catalogFileURL, recreateOnSchemaMismatch: true) }
        catch {
            removeCatalogFiles()
            do { db = try CatalogDatabase.open(at: catalogFileURL, recreateOnSchemaMismatch: true) }
            catch { catalogFailure = "\(error)"; return }
        }
        guard let opened = db else { return }
        var rebuild = forceRebuild
        if !rebuild, let issues = try? await opened.integrityCheck(), !issues.isEmpty { rebuild = true }
        do {
            if rebuild { try await rebuildContents(of: opened, progress: progress) } else { try await reconcile(opened) }
            catalog = opened
            return
        } catch {
            await opened.close()
        }
        // Second chance: a fresh file rebuilt from the packages.
        removeCatalogFiles()
        do {
            let fresh = try CatalogDatabase.open(at: catalogFileURL, recreateOnSchemaMismatch: true)
            do { try await rebuildContents(of: fresh, progress: progress); catalog = fresh }
            catch { await fresh.close(); catalogFailure = "\(error)" }
        } catch { catalogFailure = "\(error)" }
    }

    private func removeCatalogFiles() {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? fileSystem.removeItem(at: URL(fileURLWithPath: catalogFileURL.path + suffix))
        }
    }

    /// Drops every row and catalogues the folders and every package again.
    private func rebuildContents(of db: CatalogDatabase, progress: (@Sendable (ImportProgress) -> Void)?) async throws {
        let manifest = try await store.manifest()
        try await db.reset()
        try await db.upsertFolders(manifest)
        let listings = try await store.listDocuments()
        for (index, listing) in listings.enumerated() {
            progress?(ImportProgress(completedUnits: index, totalUnits: listings.count, message: "Indexing \(listing.document.title)"))
            try await catalogListing(listing, in: db)
        }
        progress?(ImportProgress(completedUnits: listings.count, totalUnits: listings.count, message: "Catalog rebuilt"))
    }

    /// Brings an existing catalog in step with the packages: folders replaced,
    /// changed or new packages re-catalogued, rows without a package removed.
    private func reconcile(_ db: CatalogDatabase) async throws {
        let manifest = try await store.manifest()
        try await db.upsertFolders(manifest)
        let listings = try await store.listDocuments()
        let rows = Dictionary(try await db.documents(in: .all).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<DocumentID>()
        for listing in listings {
            seen.insert(listing.id)
            if let row = rows[listing.id], row.needsNewerApp == listing.needsNewerApp, row.pageCount == listing.pageCount,
               row.title == listing.document.title, row.folderID == listing.document.folderID,
               row.isFavorite == listing.document.isFavorite, row.pendingReviewCount == Self.pendingReviewCount(listing.document),
               abs(row.modifiedAt.timeIntervalSince(listing.document.modifiedAt)) < 0.002,
               (listing.needsNewerApp || row.firstPageID == listing.document.pageIDs.first) {
                continue
            }
            try await catalogListing(listing, in: db)
        }
        for id in rows.keys where !seen.contains(id) { try await db.removeDocument(id) }
    }

    private func catalogListing(_ listing: DocumentListing, in db: CatalogDatabase) async throws {
        if listing.needsNewerApp {
            try await db.upsertDocumentHeader(listing.document, pageCount: listing.pageCount, needsNewerApp: true)
            return
        }
        let (_, opened) = try await store.openDocument(listing.id)
        try await db.upsertDocument(opened.snapshot)
    }

    /// Re-catalogues one document from its package (after create, import, restore...).
    private func catalogDocument(_ id: DocumentID) async {
        guard let catalog else { return }
        guard let listing = try? await store.listing(id) else { try? await catalog.removeDocument(id); return }
        try? await catalogListing(listing, in: catalog)
    }

    private func catalogHeader(_ id: DocumentID) async {
        guard let catalog, let listing = try? await store.listing(id) else { return }
        try? await catalog.upsertDocumentHeader(listing.document, pageCount: listing.pageCount, needsNewerApp: listing.needsNewerApp)
    }

    private func syncFolders() async {
        guard let catalog, let manifest = try? await store.manifest() else { return }
        try? await catalog.upsertFolders(manifest)
    }

    // MARK: - Listing

    public func manifest() async throws -> LibraryManifest {
        try await ensureOpen()
        do { return try await store.manifest() } catch { throw translate(error) }
    }

    public func documents(in scope: LibraryScope) async throws -> [DocumentSummary] {
        try await ensureOpen()
        do {
            if case .trash = scope {
                return try await store.listTrashedDocuments().map(Self.summary)
            }
            if let catalog {
                let catalogScope: CatalogScope
                switch scope {
                case .folder(let id): catalogScope = .folder(id)
                case .recents: catalogScope = .recents(limit: 20)
                case .favorites: catalogScope = .favorites
                case .inbox: catalogScope = .inbox
                case .trash: catalogScope = .all
                }
                return try await catalog.documents(in: catalogScope).map(Self.summary)
            }
            // Catalog unavailable: derive the listing from the packages.
            let listings = try await store.listDocuments()
            let filtered: [DocumentListing]
            switch scope {
            case .folder(let id): filtered = listings.filter { $0.document.folderID == id && (id != nil || $0.document.kind != .quickNote) }
            case .recents:
                filtered = Array(listings.sorted { ($0.document.lastOpenedAt ?? $0.document.modifiedAt) > ($1.document.lastOpenedAt ?? $1.document.modifiedAt) }.prefix(20))
            case .favorites: filtered = listings.filter { $0.document.isFavorite }
            case .inbox: filtered = listings.filter { $0.document.folderID == nil && $0.document.kind == .quickNote }.sorted { $0.document.modifiedAt > $1.document.modifiedAt }
            case .trash: filtered = []
            }
            return filtered.map(Self.summary)
        } catch { throw translate(error) }
    }

    public func document(_ id: DocumentID) async throws -> DocumentSummary {
        try await ensureOpen()
        if let catalog, let row = try? await catalog.document(id) { return Self.summary(row) }
        guard let listing = try? await store.listing(id) else { throw WorkspaceError.documentNotFound(id) }
        return Self.summary(listing)
    }

    public func folders(in parent: FolderID?) async throws -> [FolderSummary] {
        let manifest = try await manifest()
        let children = manifest.folders.filter { $0.parentID == parent }
            .sorted { $0.sortIndex != $1.sortIndex ? $0.sortIndex < $1.sortIndex : $0.name.lowercased() < $1.name.lowercased() }
        var listings: [DocumentListing]? = nil
        var result: [FolderSummary] = []
        for folder in children {
            let count: Int
            if let catalog, let n = try? await catalog.documentCount(inFolder: folder.id) {
                count = n
            } else {
                if listings == nil { listings = (try? await store.listDocuments()) ?? [] }
                count = listings!.filter { $0.document.folderID == folder.id }.count
            }
            let subfolders = manifest.folders.filter { $0.parentID == folder.id }.count
            result.append(FolderSummary(folder: folder, documentCount: count, subfolderCount: subfolders))
        }
        return result
    }

    public func trashEntries() async throws -> [TrashSummary] {
        try await ensureOpen()
        do { return try await store.trashEntries().map(TrashSummary.init) } catch { throw translate(error) }
    }

    // MARK: - Folders

    public func createFolder(name: String, parentID: FolderID?, isCourse: Bool) async throws -> Folder {
        try await ensureOpen()
        if let parentID, try await manifest().folder(parentID) == nil { throw WorkspaceError.folderNotFound(parentID) }
        do {
            let folder = try await store.createFolder(name: name, parentID: parentID, isCourse: isCourse)
            await syncFolders()
            return folder
        } catch { throw translate(error) }
    }

    public func updateFolder(_ folder: Folder) async throws {
        try await ensureOpen()
        let manifest = try await manifest()
        guard manifest.folder(folder.id) != nil else { throw WorkspaceError.folderNotFound(folder.id) }
        if let parent = folder.parentID, manifest.folder(parent) == nil { throw WorkspaceError.folderNotFound(parent) }
        do { try await store.updateFolder(folder) } catch { throw translate(error) }
        await syncFolders()
    }

    public func deleteFolder(_ id: FolderID) async throws {
        try await ensureOpen()
        let manifest = try await manifest()
        guard manifest.folder(id) != nil else { throw WorkspaceError.folderNotFound(id) }
        let subtree = manifest.subtree(of: id)
        for (docID, session) in sessions {
            let folderID = await MainActor.run { session.editor.document.folderID }
            if let folderID, subtree.contains(folderID) { await closeSession(docID) }
        }
        do { try await store.deleteFolder(id) } catch { throw translate(error) }
        await syncFolders()
    }

    // MARK: - Documents

    public func createNotebook(title: String, folderID: FolderID?, template: PaperTemplate, pageSize: PageSize, cover: CoverStyle, pageCount: Int) async throws -> DocumentID {
        try await ensureOpen()
        if let folderID, try await manifest().folder(folderID) == nil { throw WorkspaceError.folderNotFound(folderID) }
        let snapshot = DocumentSnapshot.newNotebook(title: title, folderID: folderID, template: template, pageSize: pageSize,
                                                    pageCount: max(1, pageCount), kind: .notebook, cover: cover, now: clock.now())
        do { _ = try await store.createDocument(snapshot: snapshot) } catch { throw translate(error) }
        await catalogDocument(snapshot.document.id)
        return snapshot.document.id
    }

    public func createQuickNote(template: PaperTemplate) async throws -> DocumentID {
        try await ensureOpen()
        let snapshot = DocumentSnapshot.newNotebook(title: "Quick Note", folderID: nil, template: template, pageSize: .letter,
                                                    pageCount: 1, kind: .quickNote, cover: .default, now: clock.now())
        do { _ = try await store.createDocument(snapshot: snapshot) } catch { throw translate(error) }
        await catalogDocument(snapshot.document.id)
        return snapshot.document.id
    }

    public func rename(_ id: DocumentID, to title: String) async throws {
        try await ensureOpen()
        if let session = liveSession(id) {
            try await applyInSession(session) { try $0.apply(.setTitle(title)) }
            return
        }
        try await requireDocument(id)
        do { try await store.rename(id, to: title) } catch { throw translate(error) }
        await catalogHeader(id)
    }

    public func move(_ id: DocumentID, toFolder folderID: FolderID?) async throws {
        try await ensureOpen()
        if let folderID, try await manifest().folder(folderID) == nil { throw WorkspaceError.folderNotFound(folderID) }
        if let session = liveSession(id) {
            try await applyInSession(session) { try $0.setFolderID(folderID) }
            return
        }
        try await requireDocument(id)
        do { try await store.move(id, toFolder: folderID) } catch { throw translate(error) }
        await catalogHeader(id)
    }

    public func duplicate(_ id: DocumentID) async throws -> DocumentID {
        try await ensureOpen()
        let listing = try await requireDocument(id)
        if listing.needsNewerApp { throw WorkspaceError.documentNeedsNewerApp(id, schemaVersion: listing.schemaVersion) }
        if let session = liveSession(id) { try await session.flush() }
        let copyID: DocumentID
        do { copyID = try await store.duplicate(id, title: listing.document.title + " copy") } catch { throw translate(error) }
        await catalogDocument(copyID)
        return copyID
    }

    public func setFavorite(_ id: DocumentID, _ isFavorite: Bool) async throws {
        try await ensureOpen()
        if let session = liveSession(id) {
            try await applyInSession(session) { try $0.apply(.setFavorite(isFavorite)) }
            return
        }
        try await requireDocument(id)
        do { try await store.setFavorite(id, isFavorite) } catch { throw translate(error) }
        await catalogHeader(id)
    }

    public func setCover(_ id: DocumentID, _ cover: CoverStyle) async throws {
        try await ensureOpen()
        if let session = liveSession(id) {
            try await applyInSession(session) { try $0.apply(.setCover(cover)) }
            return
        }
        try await requireDocument(id)
        do { try await store.setCover(id, cover) } catch { throw translate(error) }
        await catalogHeader(id)
    }

    public func delete(_ id: DocumentID) async throws {
        try await ensureOpen()
        try await requireDocument(id)
        await closeSession(id)
        do { _ = try await store.delete(id) } catch { throw translate(error) }
        if let catalog { try? await catalog.removeDocument(id) }
    }

    public func restore(trashEntryID: UUID) async throws {
        try await ensureOpen()
        guard let entry = try await store.trashEntries().first(where: { $0.id == trashEntryID }) else {
            throw WorkspaceError.storage("trash entry \(trashEntryID) was not found")
        }
        do { try await store.restore(trashEntryID: trashEntryID) } catch { throw translate(error) }
        await syncFolders()
        switch entry.item {
        case .document(let id): await catalogDocument(id)
        case .folder(_, let ids): for id in ids { await catalogDocument(id) }
        }
    }

    public func purge(trashEntryID: UUID) async throws {
        try await ensureOpen()
        do { try await store.purge(trashEntryID: trashEntryID) } catch { throw translate(error) }
    }

    public func emptyTrash() async throws {
        try await ensureOpen()
        do { try await store.emptyTrash() } catch { throw translate(error) }
    }

    // MARK: - Sessions

    public func openSession(_ id: DocumentID) async throws -> any DocumentSessioning {
        try await ensureOpen()
        if let session = liveSession(id) { return session }
        let listing = try await requireDocument(id)
        if listing.needsNewerApp { throw WorkspaceError.documentNeedsNewerApp(id, schemaVersion: listing.schemaVersion) }
        let packageStore: DocumentPackageStore
        let opened: OpenResult
        do {
            try await store.noteOpened(id)
            (packageStore, opened) = try await store.openDocument(id)
        } catch { throw translate(error) }
        let catalog = self.catalog, clock = self.clock, sleeper = self.saveSleeper
        let debounce = saveDebounce, maxDelay = saveMaxDelay
        let session = await MainActor.run {
            DocumentSession(documentID: id, snapshot: opened.snapshot, recoveryReport: opened.report, packageStore: packageStore,
                            catalog: catalog, clock: clock, sleeper: sleeper, debounce: debounce, maxDelay: maxDelay)
        }
        sessions[id] = session
        await MainActor.run { [weak self] in
            session.onClosed = { Task { await self?.sessionDidClose(id, session) } }
        }
        if !opened.report.isClean, let catalog { try? await catalog.upsertDocument(opened.snapshot) }
        return session
    }

    public func closeSession(_ id: DocumentID) async {
        guard let session = sessions[id] else { return }
        await session.close()
        if sessions[id] === session { sessions[id] = nil }
    }

    private func sessionDidClose(_ id: DocumentID, _ session: DocumentSession) {
        if sessions[id] === session { sessions[id] = nil }
    }

    private func liveSession(_ id: DocumentID) -> DocumentSession? {
        guard let session = sessions[id] else { return nil }
        return session
    }

    private func applyInSession(_ session: DocumentSession, _ body: @escaping @MainActor (DocumentSession) throws -> Void) async throws {
        try await MainActor.run { try body(session) }
        try await session.flush()
    }

    private func flushAllSessions() async throws {
        for id in sessions.keys.sorted() { if let s = sessions[id] { try await s.flush() } }
    }

    // MARK: - Import

    public func importFiles(_ requests: [ImportRequest], destination: ImportDestination,
                            progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportResult {
        try await ensureOpen()
        guard !requests.isEmpty else { return ImportResult() }
        let coordinator = ImportCoordinator(pdfInspector: pdfInspector, imageInspector: imageInspector, clock: clock)
        let staging: URL
        do { staging = try await store.stagingDirectory() } catch { throw translate(error) }
        defer { try? fileSystem.removeItem(at: staging) }

        var targetFolder: FolderID? = nil
        var targetSession: DocumentSession? = nil
        var targetSnapshot: DocumentSnapshot? = nil
        var targetStore: DocumentPackageStore? = nil
        var insertIndex = 0
        switch destination {
        case .newNotebook(let folderID, _):
            if let folderID, try await manifest().folder(folderID) == nil { throw WorkspaceError.folderNotFound(folderID) }
            targetFolder = folderID
        case .insert(let documentID, let afterPageIndex):
            let listing = try await requireDocument(documentID)
            if listing.needsNewerApp { throw WorkspaceError.documentNeedsNewerApp(documentID, schemaVersion: listing.schemaVersion) }
            if let session = liveSession(documentID) {
                targetSession = session
                targetSnapshot = await MainActor.run { session.editor.snapshot }
            } else {
                do {
                    let (pkg, opened) = try await store.openDocument(documentID)
                    targetStore = pkg; targetSnapshot = opened.snapshot
                } catch { throw translate(error) }
            }
            let count = targetSnapshot!.document.pageIDs.count
            insertIndex = afterPageIndex.map { min(max($0 + 1, 0), count) } ?? 0
        }

        // Digests already in the library, for duplicate warnings (never a block).
        var knownDigests: [String: String] = [:]
        if let targetSnapshot {
            for asset in targetSnapshot.assets.values { knownDigests[asset.sha256] = "in this notebook" }
        } else {
            for listing in (try? await store.listDocuments()) ?? [] where !listing.needsNewerApp {
                if let (manifest, _, _) = try? DocumentPackageStore.readManifest(at: listing.packageURL, fileSystem: fileSystem) {
                    for asset in manifest.assets.values where knownDigests[asset.sha256] == nil { knownDigests[asset.sha256] = "in '\(listing.document.title)'" }
                }
            }
        }

        let revisionID = targetSnapshot?.document.revisionHead ?? RevisionID()
        var prepared = ImportCoordinator.Prepared()
        var archivedDocuments: [ImportCoordinator.ArchivedDocument] = []
        let total = requests.count + 1
        for (index, request) in requests.enumerated() {
            progress(ImportProgress(completedUnits: index, totalUnits: total, message: "Importing \(request.sourceURL.lastPathComponent)"))
            try checkCancelled()
            let staged = try coordinator.stage(request, in: staging)
            let data = (try? Data(contentsOf: staged)) ?? Data()
            let kind = coordinator.resolvedKind(of: request, data: data)
            if kind == .archive {
                let (documents, _) = try coordinator.prepareArchive(stagedURL: staged, asCopies: true)
                if targetSnapshot != nil {
                    let pages = coordinator.pages(fromArchived: documents, revisionID: revisionID)
                    prepared.pages += pages.pages; prepared.assets += pages.assets; prepared.warnings += pages.warnings
                } else {
                    archivedDocuments += documents
                }
            } else {
                let part = try coordinator.preparePages(request: request, stagedURL: staged, revisionID: revisionID, existingDigests: knownDigests)
                if prepared.suggestedTitle == nil { prepared.suggestedTitle = part.suggestedTitle }
                for asset in part.assets where knownDigests[asset.asset.sha256] == nil { knownDigests[asset.asset.sha256] = "earlier in this import" }
                prepared.pages += part.pages; prepared.assets += part.assets; prepared.warnings += part.warnings
            }
            try checkCancelled()
        }
        progress(ImportProgress(completedUnits: requests.count, totalUnits: total, message: "Saving"))

        var result = ImportResult(warnings: prepared.warnings)
        switch destination {
        case .newNotebook(_, let title):
            var toCreate: [(DocumentSnapshot, [PendingAsset])] = []
            if !prepared.pages.isEmpty {
                let now = clock.now()
                let revision = Revision(parentIDs: [], sequence: 1, createdAt: now, changedPageIDs: prepared.pages.map(\.id), summary: "Imported")
                var pages: [PageID: Page] = [:]
                for var page in prepared.pages { page.revisionID = revision.id; pages[page.id] = page }
                let notebookTitle = title ?? prepared.suggestedTitle ?? "Imported"
                let document = Document(title: notebookTitle, folderID: targetFolder, defaultPageSize: pages[prepared.pages[0].id]!.size,
                                        pageIDs: prepared.pages.map(\.id), revisionHead: revision.id, createdAt: now, modifiedAt: now)
                var assets: [AssetID: SourceAsset] = [:]
                for asset in prepared.assets { assets[asset.asset.id] = asset.asset }
                toCreate.append((DocumentSnapshot(document: document, pages: pages, assets: assets, revisions: [revision.id: revision]), prepared.assets))
            }
            for archived in archivedDocuments {
                var snapshot = archived.snapshot
                snapshot.document.folderID = targetFolder
                if let title, archivedDocuments.count == 1, prepared.pages.isEmpty { snapshot.document.title = title }
                snapshot.document.lastOpenedAt = nil
                toCreate.append((snapshot, archived.assets))
            }
            guard !toCreate.isEmpty else { throw WorkspaceError.importFailed("nothing to import") }
            result.createdDocumentIDs = try await materialize(toCreate, staging: staging)
            for (snapshot, _) in toCreate { result.insertedPageIDs += snapshot.document.pageIDs }
        case .insert:
            guard !prepared.pages.isEmpty else { throw WorkspaceError.importFailed("nothing to insert") }
            result.insertedPageIDs = prepared.pages.map(\.id)
            if let session = targetSession {
                let pages = prepared.pages, assets = prepared.assets, at = insertIndex
                try await MainActor.run {
                    try session.performGrouped("Import") {
                        for asset in assets { session.addAsset(asset) }
                        try session.apply(.insertPages(pages, at: at))
                    }
                }
                try await session.flush()
            } else if let pkg = targetStore, var snapshot = targetSnapshot {
                let editor = DocumentEditor(snapshot: snapshot, clock: clock)
                for asset in prepared.assets { editor.registerPendingAsset(asset) }
                do { try editor.apply(.insertPages(prepared.pages, at: insertIndex)) } catch { throw WorkspaceError.importFailed("\(error)") }
                snapshot = editor.snapshot
                let changes = editor.takePendingChanges()
                do { _ = try await pkg.commit(snapshot: snapshot, changes: changes) } catch { throw translate(error) }
                await catalogDocument(snapshot.document.id)
            }
        }
        progress(ImportProgress(completedUnits: total, totalUnits: total, message: "Done"))
        return result
    }

    /// Creates every package in staging first and moves them into
    /// `Documents/` only when all of them were written; on any failure nothing
    /// remains in the library.
    private func materialize(_ documents: [(DocumentSnapshot, [PendingAsset])], staging: URL) async throws -> [DocumentID] {
        var built: [(id: DocumentID, url: URL)] = []
        var moved: [URL] = []
        do {
            for (snapshot, assets) in documents {
                try checkCancelled()
                let url = staging.appendingPathComponent(PackageLayout.packageName(for: snapshot.document.id))
                _ = try await DocumentPackageStore.create(at: url, snapshot: snapshot, assets: assets, fileSystem: fileSystem, clock: clock)
                built.append((snapshot.document.id, url))
            }
            for (id, url) in built {
                let destination = store.packageURL(for: id)
                if fileSystem.directoryExists(at: destination) || fileSystem.directoryExists(at: store.trashPackageURL(for: id)) {
                    throw PersistenceError.alreadyExists(path: destination.path)
                }
                try fileSystem.moveItem(at: url, to: destination)
                moved.append(destination)
            }
        } catch {
            for url in moved { try? fileSystem.removeItem(at: url) }
            for (_, url) in built { try? fileSystem.removeItem(at: url) }
            throw translate(error)
        }
        for (id, _) in built { await catalogDocument(id) }
        return built.map(\.id)
    }

    private func checkCancelled() throws { if Task.isCancelled { throw WorkspaceError.cancelled } }

    // MARK: - Export, backup, restore

    public func exportArchive(documentIDs: [DocumentID], to url: URL, progress: @Sendable @escaping (ImportProgress) -> Void) async throws {
        try await ensureOpen()
        guard !documentIDs.isEmpty else { throw WorkspaceError.archive("no documents selected") }
        var inputs: [LibraryArchiveWriter.DocumentInput] = []
        for (index, id) in documentIDs.enumerated() {
            progress(ImportProgress(completedUnits: index, totalUnits: documentIDs.count + 1, message: "Reading document"))
            let listing = try await requireDocument(id)
            if listing.needsNewerApp { throw WorkspaceError.documentNeedsNewerApp(id, schemaVersion: listing.schemaVersion) }
            if let session = liveSession(id) { try await session.flush() }
            let opened: OpenResult
            do { opened = try await store.openDocument(id).result } catch { throw translate(error) }
            inputs.append(.init(snapshot: opened.snapshot, assetData: Self.assetProvider(packageURL: listing.packageURL)))
        }
        progress(ImportProgress(completedUnits: documentIDs.count, totalUnits: documentIDs.count + 1, message: "Writing archive"))
        do {
            try? fileSystem.removeItem(at: url)
            if inputs.count == 1 {
                try DocumentArchiveWriter.write(snapshot: inputs[0].snapshot, assetData: inputs[0].assetData, to: url, producer: producer, clock: clock)
            } else {
                let manifest = try await store.manifest()
                let library = LibraryManifest(folders: manifest.folders, trash: [], modifiedAt: manifest.modifiedAt)
                try LibraryArchiveWriter.write(library: library, documents: inputs, to: url, producer: producer, clock: clock)
            }
        } catch let error as ArchiveError { throw WorkspaceError.archive(error.description) }
        catch let error as WorkspaceError { throw error }
        catch { throw WorkspaceError.archive("\(error)") }
        progress(ImportProgress(completedUnits: documentIDs.count + 1, totalUnits: documentIDs.count + 1, message: "Done"))
    }

    public func backupLibrary(to url: URL, progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> BackupReport {
        try await ensureOpen()
        try await flushAllSessions()
        let manifest: LibraryManifest
        let listings: [DocumentListing]
        do { manifest = try await store.manifest(); listings = try await store.listDocuments() } catch { throw translate(error) }
        var inputs: [LibraryArchiveWriter.DocumentInput] = []
        let readable = listings.filter { !$0.needsNewerApp }
        for (index, listing) in readable.enumerated() {
            progress(ImportProgress(completedUnits: index, totalUnits: readable.count + 2, message: "Reading \(listing.document.title)"))
            try checkCancelled()
            let opened: OpenResult
            do { opened = try await store.openDocument(listing.id).result } catch { throw translate(error) }
            inputs.append(.init(snapshot: opened.snapshot, assetData: Self.assetProvider(packageURL: listing.packageURL)))
        }
        progress(ImportProgress(completedUnits: readable.count, totalUnits: readable.count + 2, message: "Writing backup"))
        let library = LibraryManifest(folders: manifest.folders, trash: [], modifiedAt: manifest.modifiedAt)
        do {
            try? fileSystem.removeItem(at: url)
            try LibraryArchiveWriter.write(library: library, documents: inputs, to: url, producer: producer, clock: clock)
        } catch let error as ArchiveError { throw WorkspaceError.archive(error.description) }
        catch { throw WorkspaceError.archive("\(error)") }
        progress(ImportProgress(completedUnits: readable.count + 1, totalUnits: readable.count + 2, message: "Validating backup"))
        // Validate what was written before claiming anything.
        let inventory: ArchiveInventory
        do { inventory = try ArchiveReader.inventory(url: url) }
        catch {
            try? fileSystem.removeItem(at: url)
            throw WorkspaceError.archive("backup failed validation: \((error as? ArchiveError)?.description ?? "\(error)")")
        }
        guard Set(inventory.documentIDs) == Set(inputs.map(\.snapshot.document.id)), inventory.hasLibraryManifest else {
            try? fileSystem.removeItem(at: url)
            throw WorkspaceError.archive("backup failed validation: document set differs")
        }
        progress(ImportProgress(completedUnits: readable.count + 2, totalUnits: readable.count + 2, message: "Done"))
        return BackupReport(documentCount: inventory.documents.count, byteCount: (try? fileSystem.fileSize(at: url)) ?? inventory.archiveByteCount,
                            archiveURL: url, validated: true)
    }

    public func restoreLibrary(from url: URL, mode: RestoreMode, progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> RestoreReport {
        try await ensureOpen()
        let coordinator = ImportCoordinator(pdfInspector: pdfInspector, imageInspector: imageInspector, clock: clock)
        let staging: URL
        do { staging = try await store.stagingDirectory() } catch { throw translate(error) }
        defer { try? fileSystem.removeItem(at: staging) }
        progress(ImportProgress(completedUnits: 0, totalUnits: 3, message: "Validating archive"))
        let (documents, archivedLibrary) = try coordinator.prepareArchive(stagedURL: url, asCopies: mode == .addCopies)
        try checkCancelled()

        var manifest = try await manifest()
        var warnings: [String] = []
        // Folders: add every archived folder that does not exist yet (parents first).
        var newFolders: [Folder] = []
        if let archivedLibrary {
            let known = Set(manifest.folders.map(\.id))
            var remaining = archivedLibrary.folders.filter { !known.contains($0.id) }
            let candidates = known.union(remaining.map(\.id))
            for index in remaining.indices where remaining[index].parentID.map({ !candidates.contains($0) }) ?? false {
                warnings.append("Folder '\(remaining[index].name)' was placed at the root; its parent is not in the backup")
                remaining[index].parentID = nil
            }
            // Parents before children so each can be added in order.
            var placed = known
            while !remaining.isEmpty {
                let ready = remaining.filter { $0.parentID.map(placed.contains) ?? true }
                guard !ready.isEmpty else { break }
                newFolders += ready
                for f in ready { placed.insert(f.id) }
                remaining.removeAll { f in ready.contains { $0.id == f.id } }
            }
            newFolders += remaining.map { var f = $0; f.parentID = nil; return f }
        }
        let allFolderIDs = Set(manifest.folders.map(\.id)).union(newFolders.map(\.id))

        var present = Set<DocumentID>()
        do {
            for listing in try await store.listDocuments() { present.insert(listing.id) }
            for listing in try await store.listTrashedDocuments() { present.insert(listing.id) }
        } catch { throw translate(error) }

        var toCreate: [(DocumentSnapshot, [PendingAsset])] = []
        var skipped: [DocumentID] = []
        for archived in documents {
            var snapshot = archived.snapshot
            if mode == .restoreMissing && present.contains(archived.originalID) { skipped.append(archived.originalID); continue }
            if let folderID = snapshot.document.folderID, !allFolderIDs.contains(folderID) {
                warnings.append("'\(snapshot.document.title)' was filed at the root; its folder is not in the backup")
                snapshot.document.folderID = nil
            }
            snapshot.document.lastOpenedAt = nil
            toCreate.append((snapshot, archived.assets))
        }
        progress(ImportProgress(completedUnits: 1, totalUnits: 3, message: "Restoring \(toCreate.count) document(s)"))
        let restored = try await materialize(toCreate, staging: staging)
        if !newFolders.isEmpty {
            do {
                for folder in newFolders {
                    manifest = try await store.manifest()
                    if manifest.folder(folder.id) == nil {
                        try await store.addFolder(folder)
                    }
                }
            } catch {
                warnings.append("Folders could not be restored: \(error)")
            }
            await syncFolders()
        }
        progress(ImportProgress(completedUnits: 3, totalUnits: 3, message: "Done"))
        return RestoreReport(restoredDocumentIDs: restored, skippedDocumentIDs: skipped, restoredFolderCount: newFolders.count, warnings: warnings)
    }

    /// Synchronous asset reader over a package directory for the archive writers.
    private static func assetProvider(packageURL: URL) -> AssetDataProvider {
        { asset in
            let url = packageURL.appendingPathComponent(asset.relativePath)
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw ArchiveError.io("asset \(asset.sha256): \(error.localizedDescription)") }
            guard SHA256.hexDigest(data) == asset.sha256 else { throw ArchiveError.checksumMismatch(asset.relativePath) }
            return data
        }
    }

    // MARK: - Search and review

    public func search(_ query: String, scope: SearchScope) async throws -> SearchResults {
        try await ensureOpen()
        guard let catalog else { throw WorkspaceError.catalogUnavailable(catalogFailure ?? "the search index is unavailable") }
        var documentIDs: Set<DocumentID>? = nil
        switch scope {
        case .library: break
        case .document(let id): documentIDs = [id]
        case .folder(let folderID):
            let manifest = try await manifest()
            var ids = Set<DocumentID>()
            for folder in manifest.subtree(of: folderID) {
                for row in (try? await catalog.documents(in: .folder(folder))) ?? [] { ids.insert(row.id) }
            }
            documentIDs = ids
        }
        do {
            let rows = try await catalog.search(query, documentIDs: documentIDs)
            let hits = rows.map { SearchHit(documentID: $0.documentID, documentTitle: $0.documentTitle, pageID: $0.pageID, pageIndex: $0.pageIndex,
                                            revisionID: $0.revisionID, kind: $0.kind, snippet: $0.snippet, bounds: $0.bounds) }
            let notYet = try await catalog.notYetIndexedCount(documentIDs: documentIDs)
            let failed = try await catalog.failedCount(documentIDs: documentIDs)
            var inProgress = false
            for (id, session) in sessions where documentIDs?.contains(id) ?? true {
                let queued = await session.queuedRecognitionPages
                if !queued.isEmpty { inProgress = true; break }
            }
            return SearchResults(query: query, hits: hits, notYetIndexedPageCount: notYet, failedPageCount: failed, isIndexingInProgress: inProgress)
        } catch { throw WorkspaceError.catalogUnavailable("\(error)") }
    }

    public func reviewQueue(courseID: FolderID?) async throws -> [ReviewQueueEntry] {
        try await ensureOpen()
        let manifest = try await manifest()
        var folderIDs: Set<FolderID>? = nil
        if let courseID {
            guard manifest.folder(courseID) != nil else { throw WorkspaceError.folderNotFound(courseID) }
            folderIDs = manifest.subtree(of: courseID)
        }
        func entry(item: ReviewItem, documentID: DocumentID, title: String, folderID: FolderID?, pageIndex: Int,
                   problemTitle: String?, problemStatus: ProblemStatus?) -> ReviewQueueEntry {
            let course = manifest.courseFolder(containing: folderID)
            return ReviewQueueEntry(item: item, documentID: documentID, documentTitle: title, courseID: course?.id, courseName: course?.name,
                                    pageIndex: pageIndex, problemTitle: problemTitle, problemStatus: problemStatus)
        }
        if let catalog {
            do {
                let rows = try await catalog.reviewQueue(folderIDs: folderIDs, includeUnfiled: folderIDs == nil)
                return rows.map { entry(item: $0.reviewItem, documentID: $0.documentID, title: $0.documentTitle, folderID: $0.folderID,
                                        pageIndex: $0.pageIndex, problemTitle: $0.problemTitle, problemStatus: $0.problemStatus) }
            } catch { /* fall through to the package scan */ }
        }
        // Catalog unavailable: scan the packages.
        var entries: [ReviewQueueEntry] = []
        for listing in (try? await store.listDocuments()) ?? [] where !listing.needsNewerApp {
            let folderID = listing.document.folderID
            if let folderIDs { guard let folderID, folderIDs.contains(folderID) else { continue } }
            guard let opened = try? await store.openDocument(listing.id).result else { continue }
            let snapshot = opened.snapshot
            for item in ReviewRules.pendingItems(in: snapshot) {
                guard let index = snapshot.pageIndex(item.pageID) else { continue }
                let page = snapshot.page(item.pageID)
                entries.append(entry(item: item, documentID: listing.id, title: listing.document.title, folderID: folderID, pageIndex: index,
                                     problemTitle: page?.problem?.title, problemStatus: page?.problem?.status))
            }
        }
        return entries.sorted { a, b in
            if a.item.createdAt != b.item.createdAt { return a.item.createdAt < b.item.createdAt }
            if a.documentTitle.lowercased() != b.documentTitle.lowercased() { return a.documentTitle.lowercased() < b.documentTitle.lowercased() }
            return a.pageIndex != b.pageIndex ? a.pageIndex < b.pageIndex : a.item.id < b.item.id
        }
    }

    public func markReviewed(_ itemID: ReviewItemID, in documentID: DocumentID) async throws {
        try await applyCommands([.markReviewed(itemID, at: clock.now())], to: documentID)
    }

    public func reopenReview(_ itemID: ReviewItemID, in documentID: DocumentID) async throws {
        try await applyCommands([.reopenReview(itemID, at: clock.now())], to: documentID)
    }

    /// Applies commands through the open session, or by opening the package,
    /// applying, committing and re-cataloguing when the document is not open.
    private func applyCommands(_ commands: [EditCommand], to documentID: DocumentID) async throws {
        try await ensureOpen()
        if let session = liveSession(documentID) {
            try await applyInSession(session) { session in
                try session.performGrouped(commands.first?.actionName ?? "Edit") { for command in commands { try session.apply(command) } }
            }
            return
        }
        let listing = try await requireDocument(documentID)
        if listing.needsNewerApp { throw WorkspaceError.documentNeedsNewerApp(documentID, schemaVersion: listing.schemaVersion) }
        let pkg: DocumentPackageStore
        let opened: OpenResult
        do { (pkg, opened) = try await store.openDocument(documentID) } catch { throw translate(error) }
        let editor = DocumentEditor(snapshot: opened.snapshot, clock: clock)
        do { for command in commands { try editor.apply(command) } } catch { throw WorkspaceError.storage("\(error)") }
        let changes = editor.takePendingChanges()
        do { _ = try await pkg.commit(snapshot: editor.snapshot, changes: changes) } catch { throw translate(error) }
        await catalogDocument(documentID)
    }

    // MARK: - Maintenance

    public func rebuildCatalog(progress: @Sendable @escaping (ImportProgress) -> Void) async throws {
        try await ensureOpen()
        try await flushAllSessions()
        await openCatalog(forceRebuild: true, progress: progress)
        guard let catalog else { throw WorkspaceError.catalogUnavailable(catalogFailure ?? "the catalog could not be rebuilt") }
        // Open sessions were wired to the catalog that was just replaced; hand them the new one.
        for session in sessions.values {
            let snapshot = await MainActor.run { session.catalog = catalog; return session.editor.snapshot }
            try? await catalog.upsertDocument(snapshot)
        }
    }

    public func storageReport() async throws -> StorageReport {
        try await ensureOpen()
        do {
            let report = try await store.storageReport()
            return StorageReport(documentBytes: report.documentBytes, trashBytes: report.trashBytes, catalogBytes: report.catalogBytes,
                                 previewBytes: report.previewBytes, availableBytes: report.availableBytes)
        } catch { throw translate(error) }
    }

    // MARK: - Helpers

    @discardableResult
    private func requireDocument(_ id: DocumentID) async throws -> DocumentListing {
        guard let listing = try? await store.listing(id) else { throw WorkspaceError.documentNotFound(id) }
        return listing
    }

    static func pendingReviewCount(_ document: Document) -> Int {
        let live = Set(document.pageIDs)
        return document.reviewItems.filter { $0.state == .pending && live.contains($0.pageID) }.count
    }

    static func summary(_ row: DocumentRow) -> DocumentSummary {
        DocumentSummary(id: row.id, title: row.title, kind: row.kind, folderID: row.folderID, cover: row.cover, pageCount: row.pageCount,
                        createdAt: row.createdAt, modifiedAt: row.modifiedAt, lastOpenedAt: row.lastOpenedAt, isFavorite: row.isFavorite,
                        firstPageID: row.firstPageID, pendingReviewCount: row.pendingReviewCount, needsNewerApp: row.needsNewerApp)
    }

    static func summary(_ listing: DocumentListing) -> DocumentSummary {
        let d = listing.document
        return DocumentSummary(id: d.id, title: d.title, kind: d.kind, folderID: d.folderID, cover: d.cover, pageCount: listing.pageCount,
                               createdAt: d.createdAt, modifiedAt: d.modifiedAt, lastOpenedAt: d.lastOpenedAt, isFavorite: d.isFavorite,
                               firstPageID: d.pageIDs.first, pendingReviewCount: pendingReviewCount(d), needsNewerApp: listing.needsNewerApp)
    }

    private func translate(_ error: Error) -> WorkspaceError {
        if let w = error as? WorkspaceError { return w }
        if let p = error as? PersistenceError {
            switch p {
            case .unsupportedSchema(let v): return .storage("format version \(v) needs a newer app")
            case .notFound(let what): return .storage("\(what) was not found")
            default: return .storage(p.description)
            }
        }
        if let a = error as? ArchiveError { return .archive(a.description) }
        if let c = error as? CatalogError { return .catalogUnavailable("\(c)") }
        if error is CancellationError { return .cancelled }
        return .storage("\(error)")
    }
}
