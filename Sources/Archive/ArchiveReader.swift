import Foundation
import DocumentCore

/// What a validated archive contains. Produced only after every check in
/// docs/FORMAT.md section 4 passed.
public struct ArchiveInventory: Hashable, Sendable {
    public struct DocumentEntry: Hashable, Sendable, Identifiable {
        public var id: DocumentID
        public var title: String
        public var kind: DocumentKind
        public var pageCount: Int
        public var folderID: FolderID?
        public var modifiedAt: Date
        /// Bytes of the document's entries inside the archive.
        public var byteCount: Int
    }
    public var kind: ArchiveKind
    public var formatVersion: Int
    public var createdAt: Date
    public var producer: String
    /// Sum of entry sizes (equal to `archive.json`'s `totalSize`).
    public var totalSize: Int
    /// Size of the archive file on disk.
    public var archiveByteCount: Int
    public var entryCount: Int
    /// Documents in the archive, sorted by ID.
    public var documents: [DocumentEntry]
    public var hasLibraryManifest: Bool
    public var documentIDs: [DocumentID] { documents.map(\.id) }
}

/// Opens a `.courseleaf` archive read-only and validates all of it before
/// exposing anything. Never writes to disk. Safe to share across tasks; entry
/// reads are serialized on the underlying file handle.
public final class ArchiveReader: @unchecked Sendable {
    public let url: URL
    public let limits: ArchiveLimits
    public let manifest: ArchiveManifest
    public let inventory: ArchiveInventory
    private let zip: ZipReader
    private let snapshots: [DocumentID: DocumentSnapshot]
    private let libraryManifest: LibraryManifest?
    private let records: [String: ArchiveEntryRecord]

    /// Validates the archive at `url` completely. Throws the first
    /// `ArchiveError` found; a thrown error means nothing about the archive
    /// should be trusted.
    public static func open(url: URL, limits: ArchiveLimits = .default) throws -> ArchiveReader {
        try ArchiveReader(url: url, limits: limits)
    }

    /// Validates the archive and returns only its inventory (for a preview
    /// before the user chooses what to restore). Same checks as `open`.
    public static func inventory(url: URL, limits: ArchiveLimits = .default) throws -> ArchiveInventory {
        try ArchiveReader(url: url, limits: limits).inventory
    }

    /// The validated snapshot of one document and a provider for its asset
    /// bytes. Each asset read is CRC- and SHA-256-checked again against the
    /// archive manifest, so a file modified after `open` is still detected.
    public func document(_ id: DocumentID) throws -> (snapshot: DocumentSnapshot, assetData: AssetDataProvider) {
        guard let snapshot = snapshots[id] else { throw ArchiveError.documentNotFound(id) }
        let dir = ArchivePath.documentDirectory(id)
        let provider: AssetDataProvider = { [self] asset in
            let path = dir + "/" + asset.relativePath
            guard let record = self.records[path], let entry = self.zip.entry(named: path) else { throw ArchiveError.missingEntry(path) }
            let data = try self.zip.data(for: entry)
            guard data.count == record.size, data.count == asset.byteCount else { throw ArchiveError.sizeMismatch(path) }
            guard SHA256.hexDigest(data) == record.sha256, record.sha256 == asset.sha256 else { throw ArchiveError.checksumMismatch(path) }
            return data
        }
        return (snapshot, provider)
    }

    /// `library.json` for library backups; nil for document archives.
    public func library() -> LibraryManifest? { libraryManifest }

    /// Raw bytes of any listed entry, verified against `archive.json`.
    public func entryData(path: String) throws -> Data {
        guard let record = records[path] ?? (path == ArchiveManifest.fileName ? ArchiveEntryRecord(path: path, size: -1, sha256: "") : nil),
              let entry = zip.entry(named: path) else { throw ArchiveError.missingEntry(path) }
        let data = try zip.data(for: entry)
        if record.size >= 0 {
            guard data.count == record.size else { throw ArchiveError.sizeMismatch(path) }
            guard SHA256.hexDigest(data) == record.sha256 else { throw ArchiveError.checksumMismatch(path) }
        }
        return data
    }

    // MARK: - Validation

    private init(url: URL, limits: ArchiveLimits) throws {
        self.url = url
        self.limits = limits

        // 1. ZIP structure.
        let zip = try ZipReader(url: url)
        self.zip = zip
        guard zip.entries.count <= limits.maxEntries else { throw ArchiveError.tooManyEntries }
        guard zip.fileSize <= UInt64(Int.max) else { throw ArchiveError.totalSizeExceeded }
        let fileSize = Int(zip.fileSize)

        // 2. Syntax of every entry name and a first pass over ZIP-declared sizes.
        var zipTotal = 0
        for e in zip.entries {
            try ArchivePath.validate(e.name)
            guard e.size <= UInt64(limits.maxEntryBytes) else { throw ArchiveError.entryTooLarge(e.name) }
            zipTotal += Int(e.size)
            guard zipTotal <= limits.totalBytes else { throw ArchiveError.totalSizeExceeded }
        }
        guard Double(zipTotal) <= limits.expansionRatio * Double(fileSize) else { throw ArchiveError.expansionRatioExceeded }

        // 3. archive.json.
        guard let manifestEntry = zip.entry(named: ArchiveManifest.fileName) else { throw ArchiveError.missingEntry(ArchiveManifest.fileName) }
        let manifest: ArchiveManifest
        do { manifest = try DocumentJSON.decoder().decode(ArchiveManifest.self, from: try zip.data(for: manifestEntry)) }
        catch let e as ArchiveError { throw e }
        catch { throw ArchiveError.invalidManifest("\(error)") }
        self.manifest = manifest
        guard DocumentSchema.isReadable(manifest.formatVersion) else { throw ArchiveError.unsupportedSchema(manifest.formatVersion) }
        guard manifest.entries.count <= limits.maxEntries, manifest.entries.count + 1 <= limits.maxEntries else { throw ArchiveError.tooManyEntries }
        guard manifest.totalSize >= 0, manifest.totalSize <= limits.totalBytes else { throw ArchiveError.totalSizeExceeded }
        var records: [String: ArchiveEntryRecord] = [:]
        var declaredTotal = 0
        for r in manifest.entries {
            try ArchivePath.validate(r.path)
            guard r.path != ArchiveManifest.fileName else { throw ArchiveError.invalidManifest("archive.json lists itself") }
            guard records[r.path] == nil else { throw ArchiveError.duplicateEntry(r.path) }
            guard r.size >= 0 else { throw ArchiveError.sizeMismatch(r.path) }
            guard r.size <= limits.maxEntryBytes else { throw ArchiveError.entryTooLarge(r.path) }
            guard ArchivePath.isHexDigest(Substring(r.sha256)) else { throw ArchiveError.invalidManifest("entry '\(r.path)' has a malformed sha256") }
            let (sum, overflow) = declaredTotal.addingReportingOverflow(r.size)
            guard !overflow, sum <= limits.totalBytes else { throw ArchiveError.totalSizeExceeded }
            declaredTotal = sum
            records[r.path] = r
        }
        guard declaredTotal == manifest.totalSize else { throw ArchiveError.sizeMismatch(ArchiveManifest.fileName) }
        guard Double(declaredTotal) <= limits.expansionRatio * Double(fileSize) else { throw ArchiveError.expansionRatioExceeded }
        self.records = records

        // 4. Listed vs present, declared vs ZIP sizes.
        for e in zip.entries where e.name != ArchiveManifest.fileName {
            guard let r = records[e.name] else { throw ArchiveError.unlistedEntry(e.name) }
            guard UInt64(r.size) == e.size else { throw ArchiveError.sizeMismatch(e.name) }
        }
        for r in manifest.entries where zip.entry(named: r.path) == nil { throw ArchiveError.missingEntry(r.path) }

        // 5. Layout: every listed path must belong to the documented tree.
        var docPaths: [DocumentID: [String]] = [:]
        var sawLibrary = false
        for r in manifest.entries {
            if r.path == ArchiveManifest.libraryFileName {
                guard manifest.kind == .library else { throw ArchiveError.unexpectedEntry(r.path) }
                sawLibrary = true
                continue
            }
            guard let (id, rest) = ArchivePath.documentComponent(of: r.path) else { throw ArchiveError.unexpectedEntry(r.path) }
            let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
            switch (parts.count, parts.first.map(String.init)) {
            case (1, "manifest.json"): break
            case (2, "pages") where parts[1].hasSuffix(".json"): break
            case (2, "revisions") where parts[1].hasSuffix(".json"): break
            case (3, "assets") where parts[1].count == 2: break
            default: throw ArchiveError.unexpectedEntry(r.path)
            }
            docPaths[id, default: []].append(r.path)
        }
        if manifest.kind == .library && !sawLibrary { throw ArchiveError.missingEntry(ArchiveManifest.libraryFileName) }
        if manifest.kind == .document && docPaths.isEmpty { throw ArchiveError.invalidManifest("document archive contains no document") }

        // 6. Content digests of every entry, streamed; asset names must equal their digest.
        for r in manifest.entries {
            let entry = zip.entry(named: r.path)!
            var hasher = SHA256.Hasher()
            try zip.forEachChunk(of: entry) { hasher.update($0) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == r.sha256 else { throw ArchiveError.checksumMismatch(r.path) }
            if let (_, rest) = ArchivePath.documentComponent(of: r.path), rest.hasPrefix("assets/") {
                let parts = rest.split(separator: "/")
                let file = parts[2]
                guard let dot = file.lastIndex(of: "."), ArchivePath.isHexDigest(file[..<dot]), file[..<dot] == digest,
                      parts[1] == digest.prefix(2) else { throw ArchiveError.assetNameMismatch(r.path) }
            }
        }

        // 7. Every document decodes, references resolve, and the snapshot validates.
        var snapshots: [DocumentID: DocumentSnapshot] = [:]
        var entries: [ArchiveInventory.DocumentEntry] = []
        for id in docPaths.keys.sorted() {
            let snapshot = try Self.loadDocument(id: id, paths: Set(docPaths[id]!), zip: zip, records: records)
            snapshots[id] = snapshot
            let bytes = docPaths[id]!.reduce(0) { $0 + (records[$1]?.size ?? 0) }
            let d = snapshot.document
            entries.append(.init(id: id, title: d.title, kind: d.kind, pageCount: d.pageCount, folderID: d.folderID,
                                 modifiedAt: d.modifiedAt, byteCount: bytes))
        }
        self.snapshots = snapshots

        // 8. library.json.
        var library: LibraryManifest? = nil
        if sawLibrary {
            let data = try zip.data(named: ArchiveManifest.libraryFileName)
            do { library = try DocumentJSON.decoder().decode(LibraryManifest.self, from: data) }
            catch { throw ArchiveError.invalidManifest("library.json: \(error)") }
            guard DocumentSchema.isReadable(library!.schemaVersion) else { throw ArchiveError.unsupportedSchema(library!.schemaVersion) }
        }
        self.libraryManifest = library

        inventory = ArchiveInventory(kind: manifest.kind, formatVersion: manifest.formatVersion, createdAt: manifest.createdAt,
                                     producer: manifest.producer, totalSize: manifest.totalSize, archiveByteCount: fileSize,
                                     entryCount: zip.entries.count, documents: entries, hasLibraryManifest: sawLibrary)
    }

    private static func loadDocument(id: DocumentID, paths: Set<String>, zip: ZipReader, records: [String: ArchiveEntryRecord]) throws -> DocumentSnapshot {
        let dir = ArchivePath.documentDirectory(id)
        let manifestPath = dir + "/manifest.json"
        guard paths.contains(manifestPath) else { throw ArchiveError.missingEntry(manifestPath) }
        let decoder = DocumentJSON.decoder()
        func decode<T: Decodable>(_ type: T.Type, at path: String) throws -> T {
            let data = try zip.data(named: path)
            do { return try decoder.decode(type, from: data) }
            catch { throw ArchiveError.invalidDocument(["\(path): \(error)"]) }
        }
        let manifest = try decode(ArchivedDocumentManifest.self, at: manifestPath)
        guard DocumentSchema.isReadable(manifest.formatVersion) else { throw ArchiveError.unsupportedSchema(manifest.formatVersion) }
        guard DocumentSchema.isReadable(manifest.document.schemaVersion) else { throw ArchiveError.unsupportedSchema(manifest.document.schemaVersion) }
        guard manifest.document.id == id else { throw ArchiveError.invalidDocument(["\(manifestPath): document id \(manifest.document.id) does not match its directory"]) }

        var referenced: Set<String> = [manifestPath]

        // Assets: record <-> file, both ways.
        var assets: [AssetID: SourceAsset] = [:]
        for (key, asset) in manifest.assets {
            guard key == asset.id.description else { throw ArchiveError.invalidDocument(["\(manifestPath): asset key \(key) does not match id \(asset.id)"]) }
            let path = dir + "/" + asset.relativePath
            guard let record = records[path], paths.contains(path) else { throw ArchiveError.missingEntry(path) }
            guard record.size == asset.byteCount else { throw ArchiveError.sizeMismatch(path) }
            guard record.sha256 == asset.sha256 else { throw ArchiveError.checksumMismatch(path) }
            referenced.insert(path)
            assets[asset.id] = asset
        }

        // Page files.
        var pages: [PageID: Page] = [:]
        for (key, pf) in manifest.pageFiles {
            guard let pageID = PageID(uuidString: key), pageID.description == key else { throw ArchiveError.invalidDocument(["\(manifestPath): bad page key \(key)"]) }
            let path = dir + "/" + pf.file
            guard pf.file.hasPrefix("pages/"), let record = records[path], paths.contains(path) else { throw ArchiveError.missingEntry(path) }
            guard record.sha256 == pf.sha256 else { throw ArchiveError.checksumMismatch(path) }
            let page = try decode(Page.self, at: path)
            guard page.id == pageID else { throw ArchiveError.invalidDocument(["\(path): page id \(page.id) does not match key \(key)"]) }
            guard pf.file == ArchivedDocumentManifest.pageFileName(pageID: page.id, revisionID: page.revisionID) else {
                throw ArchiveError.invalidDocument(["\(path): file name does not match page/revision ids"])
            }
            referenced.insert(path)
            pages[pageID] = page
        }
        for pageID in manifest.document.pageIDs where pages[pageID] == nil {
            throw ArchiveError.missingEntry(dir + "/pages/\(pageID)-*.json")
        }

        // Revisions: every file present decodes; the head must exist.
        var revisions: [RevisionID: Revision] = [:]
        for path in paths.sorted() where path.hasPrefix(dir + "/revisions/") {
            let rev = try decode(Revision.self, at: path)
            guard path == dir + "/" + ArchivedDocumentManifest.revisionFileName(rev.id) else {
                throw ArchiveError.invalidDocument(["\(path): file name does not match revision id \(rev.id)"])
            }
            guard DocumentSchema.isReadable(rev.schemaVersion) else { throw ArchiveError.unsupportedSchema(rev.schemaVersion) }
            revisions[rev.id] = rev
            referenced.insert(path)
        }
        let headPath = dir + "/" + ArchivedDocumentManifest.revisionFileName(manifest.document.revisionHead)
        guard revisions[manifest.document.revisionHead] != nil else { throw ArchiveError.missingEntry(headPath) }

        // Nothing unaccounted for inside the document directory.
        for path in paths.sorted() where !referenced.contains(path) { throw ArchiveError.unexpectedEntry(path) }

        let snapshot = DocumentSnapshot(document: manifest.document, pages: pages, assets: assets, revisions: revisions)
        let issues = snapshot.validate()
        guard issues.isEmpty else { throw ArchiveError.invalidDocument(issues.map(\.description)) }
        // Every asset referenced by any page has a file (validate() only checks the record).
        for assetID in snapshot.referencedAssetIDs {
            let path = dir + "/" + snapshot.assets[assetID]!.relativePath
            guard paths.contains(path) else { throw ArchiveError.missingEntry(path) }
        }
        return snapshot
    }
}
