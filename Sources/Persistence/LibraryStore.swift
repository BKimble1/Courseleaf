import Foundation
import DocumentCore

/// Lightweight description of one package for library listings.
public struct DocumentListing: Hashable, Sendable, Identifiable {
    public var document: Document
    public var pageCount: Int
    public var schemaVersion: Int
    /// The package's format is newer than `DocumentSchema.current`; it is shown read-only and never opened.
    public var needsNewerApp: Bool
    public var packageURL: URL
    public var isInTrash: Bool
    public var id: DocumentID { document.id }
}

public struct LibraryStorageReport: Hashable, Sendable {
    public var documentBytes: Int
    public var trashBytes: Int
    public var catalogBytes: Int
    public var previewBytes: Int
    public var stagingBytes: Int
    public var availableBytes: Int?
}

/// The managed library (docs/FORMAT.md section 1): `library.json` with a
/// last-known-good copy, document packages under `Documents/`, recoverable
/// `Trash/`, `Staging/` for imports, and the `Catalog/` and `Previews/`
/// directories (created here, owned by the Catalog module and the app).
public actor LibraryStore {
    public nonisolated let rootURL: URL
    public nonisolated let fileSystem: any FileSystem
    public nonisolated let clock: any Clock
    private var current: LibraryManifest?

    public init(rootURL: URL, fileSystem: any FileSystem = LocalFileSystem(), clock: any Clock = SystemClock()) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileSystem = fileSystem
        self.clock = clock
    }

    // MARK: Layout

    public nonisolated var manifestURL: URL { rootURL.appendingPathComponent(LibraryLayout.manifestFile) }
    public nonisolated var lkgManifestURL: URL { rootURL.appendingPathComponent(LibraryLayout.lkgManifestFile) }
    public nonisolated var documentsURL: URL { rootURL.appendingPathComponent(LibraryLayout.documentsDirectory) }
    public nonisolated var trashURL: URL { rootURL.appendingPathComponent(LibraryLayout.trashDirectory) }
    public nonisolated var catalogURL: URL { rootURL.appendingPathComponent(LibraryLayout.catalogDirectory) }
    public nonisolated var previewsURL: URL { rootURL.appendingPathComponent(LibraryLayout.previewsDirectory) }
    public nonisolated var stagingURL: URL { rootURL.appendingPathComponent(LibraryLayout.stagingDirectory) }

    public nonisolated func packageURL(for id: DocumentID) -> URL { documentsURL.appendingPathComponent(PackageLayout.packageName(for: id)) }
    public nonisolated func trashPackageURL(for id: DocumentID) -> URL { trashURL.appendingPathComponent(PackageLayout.packageName(for: id)) }

    // MARK: Open / manifest

    /// Creates the directory layout if needed, loads `library.json` (falling
    /// back to `library.lkg.json`) and clears `Staging/`.
    @discardableResult
    public func open() throws -> LibraryManifest {
        let fs = fileSystem
        do {
            for dir in [rootURL, documentsURL, trashURL, catalogURL, previewsURL, stagingURL] { try fs.ensureDirectory(dir) }
        } catch {
            throw PersistenceError.invalidLibraryRoot(reason: "\(error)")
        }
        let manifest = try loadManifest()
        current = manifest
        if !fs.fileExists(at: manifestURL) { try saveManifest(manifest) }
        try clearStaging()
        return manifest
    }

    public func manifest() throws -> LibraryManifest {
        if let current { return current }
        return try open()
    }

    private func loadManifest() throws -> LibraryManifest {
        let fs = fileSystem
        let decoder = DocumentJSON.decoder()
        var reasons: [String] = []
        for url in [manifestURL, lkgManifestURL] where fs.fileExists(at: url) {
            do {
                let manifest = try decoder.decode(LibraryManifest.self, from: try fs.read(at: url))
                guard DocumentSchema.isReadable(manifest.schemaVersion) else { throw PersistenceError.unsupportedSchema(version: manifest.schemaVersion) }
                return manifest
            } catch let error as PersistenceError {
                throw error
            } catch {
                reasons.append("\(url.lastPathComponent): \(error)")
            }
        }
        if reasons.isEmpty { return LibraryManifest(modifiedAt: clock.now()) }
        throw PersistenceError.invalidLibraryRoot(reason: reasons.joined(separator: "; "))
    }

    /// Writes `library.json` atomically: tmp + fsync, previous file kept as
    /// `library.lkg.json`, rename, directory sync. On failure the in-memory
    /// manifest is re-read from disk so it matches what a reader would see
    /// (a failed directory sync happens after the rename).
    private func saveManifest(_ manifest: LibraryManifest) throws {
        let fs = fileSystem
        var m = manifest
        m.modifiedAt = clock.now()
        m.schemaVersion = DocumentSchema.current
        let data = try DocumentJSON.encoder().encode(m)
        let staged = rootURL.appendingPathComponent("library.json.tmp")
        do {
            try fs.write(data, to: staged)
            try fs.syncFile(at: staged)
            if fs.fileExists(at: manifestURL) {
                let stagedLKG = rootURL.appendingPathComponent("library.lkg.json.tmp")
                if fs.fileExists(at: stagedLKG) { try fs.removeItem(at: stagedLKG) }
                try fs.copyOrLink(from: manifestURL, to: stagedLKG)
                try fs.replaceItem(at: lkgManifestURL, withItemAt: stagedLKG)
            }
            try fs.replaceItem(at: manifestURL, withItemAt: staged)
            try fs.syncDirectory(at: rootURL)
        } catch {
            if let onDisk = try? loadManifest() { current = onDisk }
            throw error
        }
        current = m
    }

    private func loaded() throws -> LibraryManifest { try manifest() }

    // MARK: Documents

    /// Creates a package under `Documents/` for `snapshot` and returns its store.
    public func createDocument(snapshot: DocumentSnapshot, assets: [PendingAsset] = []) async throws -> DocumentPackageStore {
        _ = try loaded()
        let url = packageURL(for: snapshot.document.id)
        if fileSystem.directoryExists(at: url) { throw PersistenceError.alreadyExists(path: url.path) }
        let store = DocumentPackageStore(packageURL: url, fileSystem: fileSystem, clock: clock)
        do {
            try await store.create(snapshot: snapshot, assets: assets)
        } catch {
            try? fileSystem.removeItem(at: url)
            throw error
        }
        return store
    }

    /// Opens a package in `Documents/` (never one in the trash).
    public func openDocument(_ id: DocumentID) async throws -> (store: DocumentPackageStore, result: OpenResult) {
        _ = try loaded()
        let url = packageURL(for: id)
        guard fileSystem.directoryExists(at: url) else { throw PersistenceError.packageNotFound(path: url.path) }
        let store = DocumentPackageStore(packageURL: url, fileSystem: fileSystem, clock: clock)
        let result = try await store.open()
        return (store, result)
    }

    /// Every package under `Documents/`, from a manifest-only read. Packages
    /// with a newer format are listed with `needsNewerApp`; unreadable
    /// packages are skipped (they are reported by `unreadablePackages()`).
    public func listDocuments() throws -> [DocumentListing] {
        _ = try loaded()
        return try scan(directory: documentsURL, inTrash: false)
    }

    /// Packages under `Trash/`.
    public func listTrashedDocuments() throws -> [DocumentListing] {
        _ = try loaded()
        return try scan(directory: trashURL, inTrash: true)
    }

    /// Package directories whose manifest could not be read at all (corrupt or empty).
    public func unreadablePackages() throws -> [URL] {
        _ = try loaded()
        var result: [URL] = []
        for url in try fileSystem.contentsOfDirectory(at: documentsURL) where PackageLayout.documentID(fromPackageName: url.lastPathComponent) != nil {
            if listing(at: url, inTrash: false) == nil { result.append(url) }
        }
        return result
    }

    private func scan(directory: URL, inTrash: Bool) throws -> [DocumentListing] {
        var result: [DocumentListing] = []
        for url in try fileSystem.contentsOfDirectory(at: directory) where PackageLayout.documentID(fromPackageName: url.lastPathComponent) != nil {
            if let listing = listing(at: url, inTrash: inTrash) { result.append(listing) }
        }
        return result.sorted { $0.document.title != $1.document.title ? $0.document.title < $1.document.title : $0.id < $1.id }
    }

    public func listing(_ id: DocumentID) throws -> DocumentListing {
        _ = try loaded()
        guard let l = listing(at: packageURL(for: id), inTrash: false) else { throw PersistenceError.notFound("document \(id)") }
        return l
    }

    private func listing(at url: URL, inTrash: Bool) -> DocumentListing? {
        guard let packageID = PackageLayout.documentID(fromPackageName: url.lastPathComponent) else { return nil }
        do {
            let (m, _, _) = try DocumentPackageStore.readManifest(at: url, fileSystem: fileSystem)
            return DocumentListing(document: m.document, pageCount: m.pageFiles.isEmpty ? m.document.pageIDs.count : m.document.pageIDs.count,
                                   schemaVersion: m.formatVersion, needsNewerApp: false, packageURL: url, isInTrash: inTrash)
        } catch PersistenceError.unsupportedSchema(let version) {
            // Newer format: show what we can read, never open it.
            let document = DocumentPackageStore.leniently(readDocumentAt: url, fileSystem: fileSystem)
                ?? Document(id: packageID, schemaVersion: version, title: "Needs a newer app", pageIDs: [], revisionHead: RevisionID(),
                            createdAt: clock.now(), modifiedAt: clock.now())
            return DocumentListing(document: document, pageCount: document.pageIDs.count, schemaVersion: version,
                                   needsNewerApp: true, packageURL: url, isInTrash: inTrash)
        } catch {
            return nil
        }
    }

    /// Metadata-only change to a document in `Documents/` (rename, move, favorite, cover, ...).
    /// If the document is open in an editor session, route the change through that session instead.
    public func updateDocument(_ id: DocumentID, _ mutate: @Sendable (inout Document) -> Void) async throws {
        _ = try loaded()
        let url = packageURL(for: id)
        guard fileSystem.directoryExists(at: url) else { throw PersistenceError.packageNotFound(path: url.path) }
        let store = DocumentPackageStore(packageURL: url, fileSystem: fileSystem, clock: clock)
        try await store.updateDocument(mutate)
    }

    public func rename(_ id: DocumentID, to title: String) async throws {
        let now = clock.now()
        try await updateDocument(id) { $0.title = title; $0.modifiedAt = now }
    }
    public func move(_ id: DocumentID, toFolder folderID: FolderID?) async throws {
        if let folderID { guard try loaded().folder(folderID) != nil else { throw PersistenceError.notFound("folder \(folderID)") } }
        try await updateDocument(id) { $0.folderID = folderID }
    }
    public func setFavorite(_ id: DocumentID, _ isFavorite: Bool) async throws {
        try await updateDocument(id) { $0.isFavorite = isFavorite }
    }
    public func setCover(_ id: DocumentID, _ cover: CoverStyle) async throws {
        try await updateDocument(id) { $0.cover = cover }
    }
    public func noteOpened(_ id: DocumentID) async throws {
        let now = clock.now()
        try await updateDocument(id) { $0.lastOpenedAt = now }
    }

    /// Copies a document into a new package with fresh identifiers (content equal, ids distinct).
    public func duplicate(_ id: DocumentID, title: String? = nil) async throws -> DocumentID {
        let (source, opened) = try await openDocument(id)
        var pending: [PendingAsset] = []
        for (assetID, asset) in opened.snapshot.assets.sorted(by: { $0.key < $1.key }) {
            guard let data = try await source.assetData(assetID) else { continue }
            pending.append(PendingAsset(asset: asset, data: data))
        }
        var copy = opened.snapshot.reidentified()
        if let title { copy.document.title = title }
        let now = clock.now()
        copy.document.createdAt = now
        copy.document.modifiedAt = now
        copy.document.lastOpenedAt = nil
        _ = try await createDocument(snapshot: copy, assets: pending)
        return copy.document.id
    }

    // MARK: Trash

    /// Moves the package to `Trash/` and records a `TrashEntry`.
    @discardableResult
    public func delete(_ id: DocumentID) async throws -> TrashEntry {
        var manifest = try loaded()
        let listing = try listing(id)
        let entry = TrashEntry(item: .document(id), title: listing.document.title, originalFolderID: listing.document.folderID, deletedAt: clock.now())
        manifest.trash.append(entry)
        try saveManifest(manifest)
        do {
            try movePackagesToTrash([id])
        } catch {
            manifest.trash.removeAll { $0.id == entry.id }
            try? saveManifest(manifest)
            throw error
        }
        return entry
    }

    private func movePackagesToTrash(_ ids: [DocumentID]) throws {
        for id in ids {
            let source = packageURL(for: id), destination = trashPackageURL(for: id)
            if fileSystem.directoryExists(at: destination) { throw PersistenceError.alreadyExists(path: destination.path) }
            try fileSystem.moveItem(at: source, to: destination)
        }
    }

    public func trashEntries() throws -> [TrashEntry] { try loaded().trash.sorted { $0.deletedAt != $1.deletedAt ? $0.deletedAt > $1.deletedAt : $0.id.uuidString < $1.id.uuidString } }

    /// Moves the entry's package(s) back into `Documents/`. A folder entry is
    /// re-created (under its original parent when that still exists); documents
    /// whose folder no longer exists are filed into the restored folder or the root.
    public func restore(trashEntryID: UUID) async throws {
        var manifest = try loaded()
        guard let index = manifest.trash.firstIndex(where: { $0.id == trashEntryID }) else { throw PersistenceError.notFound("trash entry \(trashEntryID)") }
        let entry = manifest.trash[index]
        var restoredFolderID: FolderID?
        let documentIDs: [DocumentID]
        switch entry.item {
        case .document(let id):
            documentIDs = [id]
        case .folder(var folder, let ids):
            documentIDs = ids
            if manifest.folder(folder.id) == nil {
                if let parent = folder.parentID, manifest.folder(parent) == nil { folder.parentID = nil }
                manifest.folders.append(folder)
            }
            restoredFolderID = folder.id
        }
        for id in documentIDs {
            let source = trashPackageURL(for: id), destination = packageURL(for: id)
            guard fileSystem.directoryExists(at: source) else { continue }
            if fileSystem.directoryExists(at: destination) { throw PersistenceError.alreadyExists(path: destination.path) }
            try fileSystem.moveItem(at: source, to: destination)
        }
        manifest.trash.remove(at: index)
        try saveManifest(manifest)
        // Fix dangling folder references after the move so the library is consistent even if this step fails.
        let known = Set(manifest.folders.map(\.id))
        for id in documentIDs where fileSystem.directoryExists(at: packageURL(for: id)) {
            if let listing = listing(at: packageURL(for: id), inTrash: false), !listing.needsNewerApp,
               let folderID = listing.document.folderID, !known.contains(folderID) {
                let target = restoredFolderID
                try await updateDocument(id) { $0.folderID = target }
            }
        }
    }

    /// Permanently deletes the entry's package(s).
    public func purge(trashEntryID: UUID) throws {
        var manifest = try loaded()
        guard let index = manifest.trash.firstIndex(where: { $0.id == trashEntryID }) else { throw PersistenceError.notFound("trash entry \(trashEntryID)") }
        let ids: [DocumentID]
        switch manifest.trash[index].item {
        case .document(let id): ids = [id]
        case .folder(_, let docs): ids = docs
        }
        for id in ids { try fileSystem.removeItem(at: trashPackageURL(for: id)) }
        manifest.trash.remove(at: index)
        try saveManifest(manifest)
    }

    public func emptyTrash() throws {
        var manifest = try loaded()
        for url in try fileSystem.contentsOfDirectory(at: trashURL) { try fileSystem.removeItem(at: url) }
        manifest.trash.removeAll()
        try saveManifest(manifest)
    }

    // MARK: Folders

    public func folders() throws -> [Folder] { try loaded().folders }

    public func createFolder(name: String, parentID: FolderID?, isCourse: Bool = false, color: CoverStyle.Palette = .slate) throws -> Folder {
        var manifest = try loaded()
        if let parentID { guard manifest.folder(parentID) != nil else { throw PersistenceError.notFound("folder \(parentID)") } }
        let siblings = manifest.folders.filter { $0.parentID == parentID }
        let folder = Folder(name: name, parentID: parentID, isCourse: isCourse, color: color, createdAt: clock.now(),
                            sortIndex: (siblings.map(\.sortIndex).max() ?? -1) + 1)
        manifest.folders.append(folder)
        try saveManifest(manifest)
        return folder
    }

    public func updateFolder(_ folder: Folder) throws {
        var manifest = try loaded()
        guard let index = manifest.folders.firstIndex(where: { $0.id == folder.id }) else { throw PersistenceError.notFound("folder \(folder.id)") }
        if let parent = folder.parentID {
            guard manifest.folder(parent) != nil else { throw PersistenceError.notFound("folder \(parent)") }
            guard !manifest.subtree(of: folder.id).contains(parent) else { throw PersistenceError.alreadyExists(path: "folder cycle") }
        }
        manifest.folders[index] = folder
        try saveManifest(manifest)
    }

    /// Trashes every document in the folder subtree, removes the subtree's
    /// folders and records one `TrashEntry` carrying the root folder.
    @discardableResult
    public func deleteFolder(_ id: FolderID) async throws -> TrashEntry {
        var manifest = try loaded()
        guard let folder = manifest.folder(id) else { throw PersistenceError.notFound("folder \(id)") }
        let subtree = manifest.subtree(of: id)
        let documents = try listDocuments().filter { $0.document.folderID.map(subtree.contains) ?? false }.map(\.id)
        let entry = TrashEntry(item: .folder(folder, documentIDs: documents), title: folder.name, originalFolderID: folder.parentID, deletedAt: clock.now())
        manifest.trash.append(entry)
        manifest.folders.removeAll { subtree.contains($0.id) }
        try saveManifest(manifest)
        try movePackagesToTrash(documents)
        return entry
    }

    // MARK: Staging and storage

    /// A fresh, unique directory under `Staging/` for an import or restore in progress.
    public func stagingDirectory() throws -> URL {
        _ = try loaded()
        let url = stagingURL.appendingPathComponent(UUID().uuidString)
        try fileSystem.createDirectory(at: url)
        return url
    }

    public func clearStaging() throws {
        try fileSystem.ensureDirectory(stagingURL)
        for url in try fileSystem.contentsOfDirectory(at: stagingURL) { try fileSystem.removeItem(at: url) }
    }

    public func storageReport() throws -> LibraryStorageReport {
        _ = try loaded()
        let fs = fileSystem
        return LibraryStorageReport(documentBytes: fs.totalSize(at: documentsURL), trashBytes: fs.totalSize(at: trashURL),
                                    catalogBytes: fs.totalSize(at: catalogURL), previewBytes: fs.totalSize(at: previewsURL),
                                    stagingBytes: fs.totalSize(at: stagingURL), availableBytes: fs.freeSpace(at: rootURL))
    }
}
