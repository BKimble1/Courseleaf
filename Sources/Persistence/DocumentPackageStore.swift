import Foundation
import DocumentCore

/// Result of a successful (or no-op) commit.
public struct CommitReceipt: Hashable, Sendable {
    /// Revision created by this commit (the previous head for a no-op).
    public var revisionID: RevisionID
    public var committedAt: Date
    public var bytesWritten: Int
    /// Package-relative paths written (assets, page files, revision, manifest).
    public var filesWritten: [String]
    public var pagesWritten: [PageID]
    public var assetsWritten: [AssetID]
    /// Pending assets whose digest already existed in the package and were not rewritten.
    public var assetsReused: [AssetID]
    /// Wall-clock time from the start of the commit to the completed directory sync.
    public var latency: TimeInterval
    /// The snapshot as committed: the store assigns the new revision to
    /// `document.revisionHead`, to every written page's `revisionID` and to `revisions`.
    public var snapshot: DocumentSnapshot
    /// True when nothing had changed and no file was written.
    public var isNoOp: Bool
}

/// How a package was opened and what had to be recovered.
public struct RecoveryReport: Hashable, Sendable {
    public enum ManifestSource: String, Hashable, Sendable { case manifest, lkgManifest }
    /// Which manifest file produced the snapshot.
    public var manifestSource: ManifestSource
    /// Why `manifest.json` was rejected, when the last-known-good file was used.
    public var rejectedManifestReason: String?
    /// Pages whose current file was missing or corrupt, with the revision whose file was used instead.
    public var recoveredPages: [PageID: RevisionID]
    /// Page files listed in the manifest that were unreadable (whether or not they were recovered).
    public var unreadablePageFiles: [PageID: String]
    /// Assets in the manifest whose file is absent from the package.
    public var missingAssets: [AssetID]
    /// Revision files that could not be decoded (skipped).
    public var unreadableRevisionFiles: [String]
    public var validationIssues: [DocumentSnapshot.ValidationIssue]

    public init(manifestSource: ManifestSource, rejectedManifestReason: String? = nil, recoveredPages: [PageID: RevisionID] = [:],
                unreadablePageFiles: [PageID: String] = [:], missingAssets: [AssetID] = [], unreadableRevisionFiles: [String] = [],
                validationIssues: [DocumentSnapshot.ValidationIssue] = []) {
        self.manifestSource = manifestSource; self.rejectedManifestReason = rejectedManifestReason
        self.recoveredPages = recoveredPages; self.unreadablePageFiles = unreadablePageFiles; self.missingAssets = missingAssets
        self.unreadableRevisionFiles = unreadableRevisionFiles; self.validationIssues = validationIssues
    }
    /// True when anything other than the plain manifest + current page files was needed.
    public var usedFallback: Bool { manifestSource == .lkgManifest || !recoveredPages.isEmpty }
    public var isClean: Bool { !usedFallback && missingAssets.isEmpty && validationIssues.isEmpty && unreadablePageFiles.isEmpty }
}

public struct OpenResult: Hashable, Sendable {
    public var snapshot: DocumentSnapshot
    public var manifest: PackageManifest
    public var report: RecoveryReport
}

public struct GarbageCollectionReport: Hashable, Sendable {
    public var removedFiles: [String]
    public var reclaimedBytes: Int
    public var retainedRevisionIDs: Set<RevisionID>
    public var keptAssetCount: Int
}

/// One document package on disk (docs/FORMAT.md section 2/3). The actor is
/// the single writer for its package: commits are serialized, follow the
/// commit protocol step by step and never report success before the manifest
/// rename and the directory sync completed.
public actor DocumentPackageStore {
    public nonisolated let packageURL: URL
    public nonisolated let fileSystem: any FileSystem
    public nonisolated let clock: any Clock
    /// Number of most recent revisions whose page files garbage collection keeps.
    public var retainedRevisionCount: Int

    private var manifest: PackageManifest?
    private var knownRevisions: [RevisionID: Revision] = [:]
    /// Every asset record this store has seen in a manifest it loaded or
    /// committed, so garbage collection can locate a pinned asset by digest
    /// even after the current table dropped it.
    private var seenAssets: [AssetID: SourceAsset] = [:]

    public init(packageURL: URL, fileSystem: any FileSystem = LocalFileSystem(), clock: any Clock = SystemClock(), retainedRevisionCount: Int = 20) {
        self.packageURL = packageURL.standardizedFileURL
        self.fileSystem = fileSystem
        self.clock = clock
        self.retainedRevisionCount = max(1, retainedRevisionCount)
    }

    public func setRetainedRevisionCount(_ count: Int) { retainedRevisionCount = max(1, count) }

    // MARK: URLs

    public nonisolated var manifestURL: URL { packageURL.appendingPathComponent(PackageLayout.manifestFile) }
    public nonisolated var lkgManifestURL: URL { packageURL.appendingPathComponent(PackageLayout.lkgManifestFile) }
    public nonisolated var tmpURL: URL { packageURL.appendingPathComponent(PackageLayout.tmpDirectory) }
    public nonisolated var pagesURL: URL { packageURL.appendingPathComponent(PackageLayout.pagesDirectory) }
    public nonisolated var assetsURL: URL { packageURL.appendingPathComponent(PackageLayout.assetsDirectory) }
    public nonisolated var revisionsURL: URL { packageURL.appendingPathComponent(PackageLayout.revisionsDirectory) }
    private nonisolated func url(_ relative: String) -> URL { packageURL.appendingPathComponent(relative) }

    public var isOpen: Bool { manifest != nil }
    /// The manifest as last committed or opened.
    public var currentManifest: PackageManifest? { manifest }
    public var currentDocument: Document? { manifest?.document }

    // MARK: Create

    /// Creates the package directory and commits `snapshot` with `assets` as
    /// the first revision. Fails with `alreadyExists` when a manifest is present.
    @discardableResult
    public func create(snapshot: DocumentSnapshot, assets: [PendingAsset] = []) throws -> CommitReceipt {
        let fs = fileSystem
        if fs.fileExists(at: manifestURL) { throw PersistenceError.alreadyExists(path: manifestURL.path) }
        try fs.createDirectory(at: packageURL)
        for dir in [pagesURL, assetsURL, revisionsURL, tmpURL] { try fs.ensureDirectory(dir) }
        // Keep the snapshot's own history (e.g. the "Created" revision) on disk.
        let encoder = DocumentJSON.encoder()
        for revision in snapshot.revisions.values.sorted(by: { $0.sequence < $1.sequence }) {
            let data = try encoder.encode(revision)
            try fs.writeAtomically(data, to: url(PackageLayout.revisionFile(revision.id)),
                                   via: tmpURL.appendingPathComponent("\(revision.id).json"))
        }
        knownRevisions = snapshot.revisions
        manifest = PackageManifest(document: snapshot.document, pageFiles: [:], assets: [:], committedAt: clock.now())
        let changes = ChangeSet(changedPageIDs: Set(snapshot.pages.keys), documentChanged: true, newAssets: assets)
        do {
            return try commit(snapshot: snapshot, changes: changes)
        } catch {
            manifest = nil; knownRevisions = [:]; seenAssets = [:]
            throw error
        }
    }

    /// Convenience: creates the store and the package in one step.
    public static func create(at url: URL, snapshot: DocumentSnapshot, assets: [PendingAsset] = [],
                              fileSystem: any FileSystem = LocalFileSystem(), clock: any Clock = SystemClock()) async throws -> DocumentPackageStore {
        let store = DocumentPackageStore(packageURL: url, fileSystem: fileSystem, clock: clock)
        try await store.create(snapshot: snapshot, assets: assets)
        return store
    }

    // MARK: Open

    /// Convenience: opens the package at `url`.
    public static func open(_ url: URL, fileSystem: any FileSystem = LocalFileSystem(), clock: any Clock = SystemClock()) async throws -> (store: DocumentPackageStore, result: OpenResult) {
        let store = DocumentPackageStore(packageURL: url, fileSystem: fileSystem, clock: clock)
        let result = try await store.open()
        return (store, result)
    }

    /// Parses the manifest (falling back to `manifest.lkg.json`), loads every
    /// page file and revision, recovers pages whose current file is missing
    /// from their most recent surviving revision file, and reports what it did.
    public func open() throws -> OpenResult {
        let fs = fileSystem
        guard fs.directoryExists(at: packageURL) else { throw PersistenceError.packageNotFound(path: packageURL.path) }
        let (loaded, source, rejection) = try loadManifest()
        var report = RecoveryReport(manifestSource: source, rejectedManifestReason: rejection)
        let decoder = DocumentJSON.decoder()

        // Revisions: everything in revisions/ that decodes.
        var revisions: [RevisionID: Revision] = [:]
        for file in (try? fs.contentsOfDirectory(at: revisionsURL)) ?? [] where file.pathExtension == "json" {
            if let data = try? fs.read(at: file), let rev = try? decoder.decode(Revision.self, from: data) {
                revisions[rev.id] = rev
            } else {
                report.unreadableRevisionFiles.append("\(PackageLayout.revisionsDirectory)/\(file.lastPathComponent)")
            }
        }

        // Pages: current file, else the newest surviving revision file for that page.
        var pages: [PageID: Page] = [:]
        let deleted = Dictionary(loaded.document.deletedPages.map { ($0.id, $0.page) }, uniquingKeysWith: { a, _ in a })
        var candidatesByPage: [PageID: [(RevisionID, URL)]] = [:]
        for (pageID, entry) in loaded.pageFiles {
            if let page = readPage(entry: entry, decoder: decoder) {
                pages[pageID] = page
                continue
            }
            report.unreadablePageFiles[pageID] = entry.file
            if candidatesByPage.isEmpty {
                for file in (try? fs.contentsOfDirectory(at: pagesURL)) ?? [] {
                    if let parsed = PackageLayout.parsePageFileName(file.lastPathComponent) {
                        candidatesByPage[parsed.pageID, default: []].append((parsed.revisionID, file))
                    }
                }
            }
            let ranked = (candidatesByPage[pageID] ?? []).sorted { a, b in
                let sa = revisions[a.0]?.sequence ?? -1, sb = revisions[b.0]?.sequence ?? -1
                return sa != sb ? sa > sb : a.1.lastPathComponent > b.1.lastPathComponent
            }
            var recovered = false
            for (revisionID, file) in ranked where file.lastPathComponent != (entry.file as NSString).lastPathComponent {
                if let data = try? fs.read(at: file), let page = try? decoder.decode(Page.self, from: data), page.id == pageID {
                    pages[pageID] = page
                    report.recoveredPages[pageID] = revisionID
                    recovered = true
                    break
                }
            }
            if !recovered {
                if let embedded = deleted[pageID] {
                    pages[pageID] = embedded
                    report.recoveredPages[pageID] = embedded.revisionID
                } else {
                    throw PersistenceError.missingPageFile(pageID: pageID)
                }
            }
        }
        for pageID in loaded.document.pageIDs where pages[pageID] == nil && loaded.pageFiles[pageID] == nil {
            throw PersistenceError.missingPageFile(pageID: pageID)
        }

        // Assets: existence on disk.
        for (id, asset) in loaded.assets.sorted(by: { $0.key < $1.key }) where !fs.fileExists(at: url(asset.relativePath)) {
            report.missingAssets.append(id)
        }

        var snapshot = DocumentSnapshot(document: loaded.document, pages: pages, assets: loaded.assets, revisions: revisions)
        snapshot.document.schemaVersion = loaded.formatVersion
        report.validationIssues = snapshot.validate()

        manifest = loaded
        knownRevisions = revisions
        remember(assetsOf: loaded)
        if case .success(let lkg)? = try? decodeManifest(at: lkgManifestURL) { remember(assetsOf: lkg) }
        clearTmp()
        return OpenResult(snapshot: snapshot, manifest: loaded, report: report)
    }

    /// Lightweight listing read: document + page count, no page content.
    /// Throws `unsupportedSchema` for a newer format instead of returning anything partial.
    public func listing() throws -> PackageManifest.Listing {
        let (loaded, _, _) = try loadManifest()
        return PackageManifest.Listing(formatVersion: loaded.formatVersion, document: loaded.document,
                                       pageCount: loaded.document.pageIDs.count, committedAt: loaded.committedAt)
    }

    private func loadManifest() throws -> (PackageManifest, RecoveryReport.ManifestSource, String?) {
        try Self.readManifest(at: packageURL, fileSystem: fileSystem)
    }

    /// Parses `manifest.json`, falling back to `manifest.lkg.json` when the
    /// former is missing or unreadable. A newer `formatVersion` throws
    /// `unsupportedSchema` immediately (never silently falls back to an older lkg).
    public nonisolated static func readManifest(at packageURL: URL, fileSystem: any FileSystem) throws -> (manifest: PackageManifest, source: RecoveryReport.ManifestSource, rejectedReason: String?) {
        let manifestURL = packageURL.appendingPathComponent(PackageLayout.manifestFile)
        let lkgURL = packageURL.appendingPathComponent(PackageLayout.lkgManifestFile)
        var rejection: String?
        switch try decodeManifest(at: manifestURL, fileSystem: fileSystem) {
        case .success(let m): return (try SchemaMigrator.migrate(m), .manifest, nil)
        case .failure(let reason): rejection = reason
        }
        switch try decodeManifest(at: lkgURL, fileSystem: fileSystem) {
        case .success(let m): return (try SchemaMigrator.migrate(m), .lkgManifest, rejection)
        case .failure(let lkgReason):
            if !fileSystem.fileExists(at: manifestURL) && !fileSystem.fileExists(at: lkgURL) {
                throw PersistenceError.packageNotFound(path: manifestURL.path)
            }
            throw PersistenceError.corruptManifest(reason: "manifest.json: \(rejection ?? "-"); manifest.lkg.json: \(lkgReason)")
        }
    }

    /// Best-effort read of the `document` object of a manifest whose format is
    /// newer than this build supports, for read-only listings. nil when the
    /// document cannot be decoded either.
    public nonisolated static func leniently(readDocumentAt packageURL: URL, fileSystem: any FileSystem) -> Document? {
        struct Partial: Decodable { var document: Document }
        for name in [PackageLayout.manifestFile, PackageLayout.lkgManifestFile] {
            let url = packageURL.appendingPathComponent(name)
            guard fileSystem.fileExists(at: url), let data = try? fileSystem.read(at: url) else { continue }
            if let partial = try? DocumentJSON.decoder().decode(Partial.self, from: data) { return partial.document }
        }
        return nil
    }

    private enum ManifestRead { case success(PackageManifest), failure(String) }

    private func decodeManifest(at url: URL) throws -> ManifestRead { try Self.decodeManifest(at: url, fileSystem: fileSystem) }

    /// Unsupported versions propagate as errors; unreadable files are reported as `.failure`.
    private nonisolated static func decodeManifest(at url: URL, fileSystem: any FileSystem) throws -> ManifestRead {
        guard fileSystem.fileExists(at: url) else { return .failure("missing") }
        let data: Data
        do { data = try fileSystem.read(at: url) } catch { return .failure("unreadable: \(error)") }
        let header: PackageManifest.Header
        do { header = try PackageManifest.decodeHeader(data) } catch { return .failure("invalid JSON: \(error)") }
        try SchemaMigrator.checkReadable(header.formatVersion)
        do { return .success(try PackageManifest.decode(data)) } catch { return .failure("undecodable: \(error)") }
    }

    private func readPage(entry: PageFileEntry, decoder: JSONDecoder) -> Page? {
        guard let data = try? fileSystem.read(at: url(entry.file)), SHA256.hexDigest(data) == entry.sha256 else { return nil }
        return try? decoder.decode(Page.self, from: data)
    }

    private func clearTmp() {
        for file in (try? fileSystem.contentsOfDirectory(at: tmpURL)) ?? [] { try? fileSystem.removeItem(at: file) }
    }

    // MARK: Commit

    /// Commits the changed parts of `snapshot` following docs/FORMAT.md section 3.
    /// The store assigns the new revision: `receipt.snapshot` carries the
    /// updated `revisionHead`, page `revisionID`s and `revisions` table.
    public func commit(snapshot input: DocumentSnapshot, changes: ChangeSet) throws -> CommitReceipt {
        guard let current = manifest else { throw PersistenceError.notOpen }
        let fs = fileSystem
        let startWall = clock.now()
        var snapshot = input
        snapshot.document.schemaVersion = DocumentSchema.current

        // Structural validation (the store owns revisions, so a stale head is not the caller's problem).
        var issues = snapshot.validate().filter { if case .missingRevisionHead = $0 { return false } else { return true } }
        for deletedPage in snapshot.document.deletedPages {
            for assetID in deletedPage.page.referencedAssetIDs where snapshot.assets[assetID] == nil {
                issues.append(.missingAsset(assetID, deletedPage.id))
            }
        }
        for pending in changes.newAssets where snapshot.assets[pending.asset.id] == nil { snapshot.assets[pending.asset.id] = pending.asset }
        issues = issues.filter { if case .missingAsset(let a, _) = $0, snapshot.assets[a] != nil { return false } else { return true } }
        if let unsupported = issues.first(where: { if case .unsupportedSchema = $0 { return true } else { return false } }),
           case .unsupportedSchema(let v) = unsupported {
            throw PersistenceError.unsupportedSchema(version: v)
        }
        if !issues.isEmpty { throw PersistenceError.invalidSnapshot(issues: issues.map(\.description)) }

        // Which pages need a new file.
        var pagesToWrite: [PageID] = []
        for (id, page) in snapshot.pages.sorted(by: { $0.key < $1.key }) {
            if changes.changedPageIDs.contains(id) { pagesToWrite.append(id); continue }
            guard let entry = current.pageFiles[id] else { pagesToWrite.append(id); continue }
            if entry.file != PackageLayout.pageFile(pageID: id, revisionID: page.revisionID) { pagesToWrite.append(id) }
        }
        var comparableDocument = snapshot.document
        comparableDocument.revisionHead = current.document.revisionHead
        let documentChanged = changes.documentChanged || comparableDocument != current.document
        let pageSetChanged = Set(snapshot.pages.keys) != Set(current.pageFiles.keys)
        let assetTableChanged = snapshot.assets != current.assets

        if pagesToWrite.isEmpty && !documentChanged && changes.newAssets.isEmpty && !pageSetChanged && !assetTableChanged {
            var committed = snapshot
            committed.document.revisionHead = current.document.revisionHead
            committed.revisions = knownRevisions
            return CommitReceipt(revisionID: current.document.revisionHead, committedAt: current.committedAt, bytesWritten: 0,
                                 filesWritten: [], pagesWritten: [], assetsWritten: [], assetsReused: [], latency: 0,
                                 snapshot: committed, isNoOp: true)
        }

        // New revision record.
        let now = clock.now()
        let sequence = (knownRevisions.values.map(\.sequence).max() ?? 0) + 1
        let parents: [RevisionID] = knownRevisions[current.document.revisionHead] != nil || !knownRevisions.isEmpty ? [current.document.revisionHead] : []
        let revision = Revision(parentIDs: parents, sequence: sequence, createdAt: now, changedPageIDs: pagesToWrite,
                                summary: pagesToWrite.isEmpty ? "Document metadata" : "\(pagesToWrite.count) page(s)")
        for id in pagesToWrite { snapshot.pages[id]?.revisionID = revision.id }
        snapshot.document.revisionHead = revision.id
        snapshot.revisions = knownRevisions
        snapshot.revisions[revision.id] = revision

        var bytesWritten = 0
        var filesWritten: [String] = []
        var assetsWritten: [AssetID] = []
        var assetsReused: [AssetID] = []
        let encoder = DocumentJSON.encoder()

        do {
            try fs.ensureDirectory(tmpURL)

            // Step 1: assets. Existing digests are reused, never rewritten.
            for pending in changes.newAssets {
                let actual = SHA256.hexDigest(pending.data)
                guard actual == pending.asset.sha256 else {
                    throw PersistenceError.assetDigestMismatch(id: pending.asset.id, expected: pending.asset.sha256, actual: actual)
                }
                let relative = pending.asset.relativePath
                let destination = url(relative)
                if fs.fileExists(at: destination) { assetsReused.append(pending.asset.id); continue }
                try fs.ensureDirectory(destination.deletingLastPathComponent())
                let staged = tmpURL.appendingPathComponent("\(pending.asset.sha256).\(pending.asset.mediaType.fileExtension)")
                try fs.write(pending.data, to: staged)
                try fs.syncFile(at: staged)
                let readBack = try fs.read(at: staged)
                guard SHA256.hexDigest(readBack) == pending.asset.sha256 else {
                    throw PersistenceError.writeFailed(path: staged.path, underlying: "digest verification after write failed")
                }
                try fs.replaceItem(at: destination, withItemAt: staged)
                bytesWritten += pending.data.count
                filesWritten.append(relative)
                assetsWritten.append(pending.asset.id)
            }

            // Step 2: changed page files.
            var pageFiles = current.pageFiles.filter { snapshot.pages[$0.key] != nil }
            for id in pagesToWrite {
                guard let page = snapshot.pages[id] else { continue }
                let data = try encoder.encode(page)
                let relative = PackageLayout.pageFile(pageID: id, revisionID: revision.id)
                bytesWritten += try fs.writeAtomically(data, to: url(relative), via: tmpURL.appendingPathComponent((relative as NSString).lastPathComponent))
                filesWritten.append(relative)
                pageFiles[id] = PageFileEntry(file: relative, sha256: SHA256.hexDigest(data))
            }

            // Step 3: revision record.
            let revisionRelative = PackageLayout.revisionFile(revision.id)
            let revisionData = try encoder.encode(revision)
            bytesWritten += try fs.writeAtomically(revisionData, to: url(revisionRelative), via: tmpURL.appendingPathComponent("\(revision.id).json"))
            filesWritten.append(revisionRelative)

            // Step 4: build and verify.
            let newManifest = PackageManifest(formatVersion: DocumentSchema.current, document: snapshot.document,
                                              pageFiles: pageFiles, assets: snapshot.assets, committedAt: now)
            try verifyReferences(of: newManifest, snapshot: snapshot)

            // Step 5: manifest via tmp, keep the previous one as lkg, atomic rename, directory sync.
            bytesWritten += try publish(newManifest)
            filesWritten.append(PackageLayout.manifestFile)
            knownRevisions[revision.id] = revision
        } catch {
            reloadAfterFailure()
            throw error
        }

        // Latency comes from the injected clock (wall time in the app, deterministic in tests).
        let latency = max(0, clock.now().timeIntervalSince(startWall))
        return CommitReceipt(revisionID: revision.id, committedAt: now, bytesWritten: bytesWritten, filesWritten: filesWritten,
                             pagesWritten: pagesToWrite, assetsWritten: assetsWritten, assetsReused: assetsReused,
                             latency: latency, snapshot: snapshot, isNoOp: false)
    }

    /// Every page file must exist with its recorded digest; every asset
    /// referenced by a live or deleted page must be in the table and on disk
    /// with the recorded byte count (its file name is its digest).
    private func verifyReferences(of manifest: PackageManifest, snapshot: DocumentSnapshot) throws {
        let fs = fileSystem
        for (pageID, entry) in manifest.pageFiles {
            guard let data = try? fs.read(at: url(entry.file)) else { throw PersistenceError.missingPageFile(pageID: pageID) }
            guard SHA256.hexDigest(data) == entry.sha256 else {
                throw PersistenceError.writeFailed(path: entry.file, underlying: "page file digest mismatch")
            }
        }
        for pageID in manifest.document.pageIDs where manifest.pageFiles[pageID] == nil {
            throw PersistenceError.missingPageFile(pageID: pageID)
        }
        var referenced = Set<AssetID>()
        for page in snapshot.pages.values { referenced.formUnion(page.referencedAssetIDs) }
        for deleted in snapshot.document.deletedPages { referenced.formUnion(deleted.page.referencedAssetIDs) }
        for id in referenced.sorted() {
            guard let asset = manifest.assets[id] else { throw PersistenceError.missingAsset(id: id) }
            let fileURL = url(asset.relativePath)
            guard fs.fileExists(at: fileURL), let size = try? fs.fileSize(at: fileURL), size == asset.byteCount else {
                throw PersistenceError.missingAsset(id: id)
            }
        }
    }

    /// After a failed commit the on-disk manifest may or may not have been
    /// replaced (a failure in the final directory sync happens after the
    /// rename), and the revision file of the failed attempt may exist. Re-read
    /// both so the in-memory head and revision table match what a reader sees.
    private func reloadAfterFailure() {
        if case .success(let m)? = try? decodeManifest(at: manifestURL), let migrated = try? SchemaMigrator.migrate(m) {
            manifest = migrated
            remember(assetsOf: migrated)
        }
        knownRevisions = readRevisionFiles()
    }

    /// Every decodable record in `revisions/`.
    private func readRevisionFiles() -> [RevisionID: Revision] {
        var revisions: [RevisionID: Revision] = [:]
        let decoder = DocumentJSON.decoder()
        for file in (try? fileSystem.contentsOfDirectory(at: revisionsURL)) ?? [] where file.pathExtension == "json" {
            if let data = try? fileSystem.read(at: file), let rev = try? decoder.decode(Revision.self, from: data) { revisions[rev.id] = rev }
        }
        return revisions
    }

    private func remember(assetsOf manifest: PackageManifest) {
        for (id, asset) in manifest.assets { seenAssets[id] = asset }
    }

    // MARK: Metadata-only commit

    /// Loads the manifest and revisions without page content, so a library
    /// operation (rename, move, favorite...) can commit a document change
    /// cheaply. No-op when the store is already open.
    public func openMetadata() throws {
        if manifest != nil { return }
        let (loaded, _, _) = try loadManifest()
        manifest = loaded
        knownRevisions = readRevisionFiles()
        remember(assetsOf: loaded)
    }

    /// Commits a change to `Document` only (steps 3-5 of the commit protocol;
    /// page files and assets are untouched but still verified).
    @discardableResult
    public func updateDocument(_ mutate: (inout Document) -> Void) throws -> CommitReceipt {
        try openMetadata()
        guard let current = manifest else { throw PersistenceError.notOpen }
        var document = current.document
        mutate(&document)
        document.revisionHead = current.document.revisionHead
        document.schemaVersion = DocumentSchema.current
        if document == current.document {
            var snapshot = DocumentSnapshot(document: document, pages: [:], assets: current.assets, revisions: knownRevisions)
            snapshot.document = document
            return CommitReceipt(revisionID: current.document.revisionHead, committedAt: current.committedAt, bytesWritten: 0, filesWritten: [],
                                 pagesWritten: [], assetsWritten: [], assetsReused: [], latency: 0, snapshot: snapshot, isNoOp: true)
        }
        // Page set must not change through this path.
        for id in document.pageIDs where current.pageFiles[id] == nil { throw PersistenceError.missingPageFile(pageID: id) }
        for deleted in document.deletedPages {
            for assetID in deleted.page.referencedAssetIDs where current.assets[assetID] == nil { throw PersistenceError.missingAsset(id: assetID) }
        }
        let fs = fileSystem
        let startWall = clock.now()
        let now = startWall
        let sequence = (knownRevisions.values.map(\.sequence).max() ?? 0) + 1
        let revision = Revision(parentIDs: [current.document.revisionHead], sequence: sequence, createdAt: now, changedPageIDs: [], summary: "Document metadata")
        document.revisionHead = revision.id
        var bytesWritten = 0
        var filesWritten: [String] = []
        do {
            try fs.ensureDirectory(tmpURL)
            let encoder = DocumentJSON.encoder()
            let revisionRelative = PackageLayout.revisionFile(revision.id)
            bytesWritten += try fs.writeAtomically(try encoder.encode(revision), to: url(revisionRelative), via: tmpURL.appendingPathComponent("\(revision.id).json"))
            filesWritten.append(revisionRelative)
            let newManifest = PackageManifest(formatVersion: DocumentSchema.current, document: document, pageFiles: current.pageFiles,
                                              assets: current.assets, committedAt: now)
            for (pageID, entry) in newManifest.pageFiles {
                guard let data = try? fs.read(at: url(entry.file)), SHA256.hexDigest(data) == entry.sha256 else {
                    throw PersistenceError.missingPageFile(pageID: pageID)
                }
            }
            bytesWritten += try publish(newManifest)
            filesWritten.append(PackageLayout.manifestFile)
            knownRevisions[revision.id] = revision
        } catch {
            reloadAfterFailure()
            throw error
        }
        var snapshot = DocumentSnapshot(document: document, pages: [:], assets: current.assets, revisions: knownRevisions)
        snapshot.document = document
        return CommitReceipt(revisionID: revision.id, committedAt: now, bytesWritten: bytesWritten, filesWritten: filesWritten, pagesWritten: [],
                             assetsWritten: [], assetsReused: [], latency: max(0, clock.now().timeIntervalSince(startWall)),
                             snapshot: snapshot, isNoOp: false)
    }

    /// Step 5: tmp manifest + fsync, previous manifest kept as lkg, atomic rename, directory sync.
    /// Sets `manifest` on success. Returns the manifest byte count.
    private func publish(_ newManifest: PackageManifest) throws -> Int {
        let fs = fileSystem
        let manifestData = try newManifest.encoded()
        let stagedManifest = tmpURL.appendingPathComponent(PackageLayout.manifestFile)
        try fs.write(manifestData, to: stagedManifest)
        try fs.syncFile(at: stagedManifest)
        if fs.fileExists(at: manifestURL) {
            let stagedLKG = tmpURL.appendingPathComponent(PackageLayout.lkgManifestFile)
            if fs.fileExists(at: stagedLKG) { try fs.removeItem(at: stagedLKG) }
            try fs.copyOrLink(from: manifestURL, to: stagedLKG)
            try fs.replaceItem(at: lkgManifestURL, withItemAt: stagedLKG)
        }
        try fs.replaceItem(at: manifestURL, withItemAt: stagedManifest)
        try fs.syncDirectory(at: packageURL)
        manifest = newManifest
        remember(assetsOf: newManifest)
        return manifestData.count
    }

    // MARK: Assets

    /// File URL of a committed asset; nil when the id is unknown or its file is absent.
    public func assetURL(_ id: AssetID) -> URL? {
        guard let asset = manifest?.assets[id] else { return nil }
        let u = url(asset.relativePath)
        return fileSystem.fileExists(at: u) ? u : nil
    }

    /// Bytes of a committed asset; nil for an unknown id, `missingAsset` when the file is gone.
    public func assetData(_ id: AssetID) throws -> Data? {
        guard let asset = manifest?.assets[id] else { return nil }
        let u = url(asset.relativePath)
        guard fileSystem.fileExists(at: u) else { throw PersistenceError.missingAsset(id: id) }
        let data = try fileSystem.read(at: u)
        guard SHA256.hexDigest(data) == asset.sha256 else { throw PersistenceError.missingAsset(id: id) }
        return data
    }

    /// Revision records known to the store (loaded on open, extended by commits).
    public var revisions: [RevisionID: Revision] { knownRevisions }

    // MARK: Garbage collection

    /// Deletes page files, revision files and asset files that are not
    /// referenced by the current manifest, `manifest.lkg.json`, the retained
    /// revisions, any deleted page or `pinnedAssetIDs` (undo history,
    /// in-flight exports). Also clears `tmp/`. Runs as its own actor call,
    /// never inside `commit`.
    ///
    /// A pinned id is located by the record in the current or lkg table, in
    /// `pinnedAssets`, or in any manifest this store loaded or committed; an
    /// id that cannot be resolved to a digest pins nothing.
    @discardableResult
    public func collectGarbage(pinnedAssetIDs: Set<AssetID> = [], pinnedAssets: [SourceAsset] = []) throws -> GarbageCollectionReport {
        guard let current = manifest else { throw PersistenceError.notOpen }
        let fs = fileSystem
        let decoder = DocumentJSON.decoder()
        var lkg: PackageManifest?
        if case .success(let m)? = try? decodeManifest(at: lkgManifestURL) { lkg = m }

        // Retained revisions: the newest `retainedRevisionCount` by sequence, plus both heads.
        let ordered = knownRevisions.values.sorted { $0.sequence != $1.sequence ? $0.sequence > $1.sequence : $0.id < $1.id }
        var retained = Set(ordered.prefix(retainedRevisionCount).map(\.id))
        retained.insert(current.document.revisionHead)
        if let lkg { retained.insert(lkg.document.revisionHead) }

        // Page files to keep.
        var keepPageFiles = Set(current.pageFiles.values.map { ($0.file as NSString).lastPathComponent })
        if let lkg { keepPageFiles.formUnion(lkg.pageFiles.values.map { ($0.file as NSString).lastPathComponent }) }
        var pageFileURLs: [URL] = []
        for file in (try? fs.contentsOfDirectory(at: pagesURL)) ?? [] {
            pageFileURLs.append(file)
            if let parsed = PackageLayout.parsePageFileName(file.lastPathComponent), retained.contains(parsed.revisionID) {
                keepPageFiles.insert(file.lastPathComponent)
            }
        }

        // Assets to keep: every table entry of both manifests, deleted pages, retained page files, pinned ids.
        var keepAssetIDs = Set(current.assets.keys).union(pinnedAssetIDs)
        if let lkg { keepAssetIDs.formUnion(lkg.assets.keys) }
        for deleted in current.document.deletedPages { keepAssetIDs.formUnion(deleted.page.referencedAssetIDs) }
        for file in pageFileURLs where keepPageFiles.contains(file.lastPathComponent) {
            if let data = try? fs.read(at: file), let page = try? decoder.decode(Page.self, from: data) {
                keepAssetIDs.formUnion(page.referencedAssetIDs)
            }
        }
        var keepAssetFiles = Set<String>()
        var tables = [current.assets, lkg?.assets ?? [:], seenAssets]
        tables.append(Dictionary(pinnedAssets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        for table in tables { for (id, asset) in table where keepAssetIDs.contains(id) { keepAssetFiles.insert("\(asset.sha256).\(asset.mediaType.fileExtension)") } }

        var removed: [String] = []
        var reclaimed = 0
        func remove(_ file: URL, _ relative: String) throws {
            reclaimed += (try? fs.fileSize(at: file)) ?? 0
            try fs.removeItem(at: file)
            removed.append(relative)
        }
        for file in pageFileURLs where !keepPageFiles.contains(file.lastPathComponent) {
            try remove(file, "\(PackageLayout.pagesDirectory)/\(file.lastPathComponent)")
        }
        for file in (try? fs.contentsOfDirectory(at: revisionsURL)) ?? [] {
            let stem = file.deletingPathExtension().lastPathComponent
            if let id = RevisionID(uuidString: stem), retained.contains(id) { continue }
            if file.pathExtension != "json" { continue }
            try remove(file, "\(PackageLayout.revisionsDirectory)/\(file.lastPathComponent)")
            if let id = RevisionID(uuidString: stem) { knownRevisions[id] = nil }
        }
        for shard in (try? fs.contentsOfDirectory(at: assetsURL)) ?? [] where fs.directoryExists(at: shard) {
            for file in (try? fs.contentsOfDirectory(at: shard)) ?? [] where !keepAssetFiles.contains(file.lastPathComponent) {
                try remove(file, "\(PackageLayout.assetsDirectory)/\(shard.lastPathComponent)/\(file.lastPathComponent)")
            }
        }
        for file in (try? fs.contentsOfDirectory(at: tmpURL)) ?? [] {
            try remove(file, "\(PackageLayout.tmpDirectory)/\(file.lastPathComponent)")
        }
        return GarbageCollectionReport(removedFiles: removed, reclaimedBytes: reclaimed, retainedRevisionIDs: retained, keptAssetCount: keepAssetFiles.count)
    }

    /// Total bytes of the package on disk.
    public func byteCount() -> Int { fileSystem.totalSize(at: packageURL) }
}
