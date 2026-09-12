import Foundation
import DocumentCore

/// Bytes of one asset, fetched on demand while the archive is being written.
public typealias AssetDataProvider = (SourceAsset) throws -> Data

/// Shared implementation: adds entries one at a time to a `ZipWriter`,
/// hashing each, and finishes with `archive.json`.
final class ArchiveBuilder {
    private let zip: ZipWriter
    private var records: [ArchiveEntryRecord] = []
    private var paths = Set<String>()
    let url: URL

    init(url: URL, now: Date) throws {
        self.url = url
        zip = try ZipWriter(url: url, modificationDate: now)
    }

    func add(path: String, data: Data) throws {
        guard !paths.contains(path) else { throw ArchiveError.duplicateEntry(path) }
        try zip.addEntry(name: path, data: data)
        records.append(ArchiveEntryRecord(path: path, size: data.count, sha256: SHA256.hexDigest(data)))
        paths.insert(path)
    }

    func add<T: Encodable>(path: String, json value: T) throws {
        try add(path: path, data: try DocumentJSON.encoder().encode(value))
    }

    /// Writes one document's assets, page files, revisions and manifest.
    func addDocument(_ snapshot: DocumentSnapshot, assetData: AssetDataProvider, includeHistory: Bool, now: Date) throws {
        let issues = snapshot.validate()
        guard issues.isEmpty else { throw ArchiveError.invalidDocument(issues.map(\.description)) }
        guard snapshot.document.schemaVersion == DocumentSchema.current else {
            throw ArchiveError.unsupportedSchema(snapshot.document.schemaVersion)
        }
        let dir = ArchivePath.documentDirectory(snapshot.document.id)

        // Assets first (largest, streamed one at a time), sorted for determinism.
        var assetTable: [String: SourceAsset] = [:]
        for id in snapshot.assets.keys.sorted() {
            let asset = snapshot.assets[id]!
            guard asset.id == id else { throw ArchiveError.invalidDocument(["asset table key \(id) does not match asset id \(asset.id)"]) }
            let path = dir + "/" + asset.relativePath
            guard ArchivePath.isHexDigest(Substring(asset.sha256)) else { throw ArchiveError.assetNameMismatch(path) }
            let data = try assetData(asset)
            guard data.count == asset.byteCount else { throw ArchiveError.sizeMismatch(path) }
            guard SHA256.hexDigest(data) == asset.sha256 else { throw ArchiveError.checksumMismatch(path) }
            try add(path: path, data: data)
            assetTable[id.description] = asset
        }

        // Page files: every page the snapshot holds (live, and deleted pages kept with content).
        var pageFiles: [String: ArchivedDocumentManifest.PageFile] = [:]
        for id in snapshot.pages.keys.sorted() {
            let page = snapshot.pages[id]!
            guard page.id == id else { throw ArchiveError.invalidDocument(["page table key \(id) does not match page id \(page.id)"]) }
            let file = ArchivedDocumentManifest.pageFileName(pageID: page.id, revisionID: page.revisionID)
            let data = try DocumentJSON.encoder().encode(page)
            try add(path: dir + "/" + file, data: data)
            pageFiles[id.description] = .init(file: file, sha256: SHA256.hexDigest(data))
        }

        // Revisions: head only, or the full history.
        let revisionIDs: [RevisionID] = includeHistory ? snapshot.revisions.keys.sorted() : [snapshot.document.revisionHead]
        for id in revisionIDs {
            guard let rev = snapshot.revisions[id], rev.id == id else { throw ArchiveError.invalidDocument(["revision \(id) is missing or mislabeled"]) }
            try add(path: dir + "/" + ArchivedDocumentManifest.revisionFileName(id), json: rev)
        }

        let manifest = ArchivedDocumentManifest(document: snapshot.document, pageFiles: pageFiles, assets: assetTable, committedAt: now)
        try add(path: dir + "/manifest.json", json: manifest)
    }

    func finish(kind: ArchiveKind, producer: String, now: Date) throws -> ArchiveManifest {
        let manifest = ArchiveManifest(kind: kind, createdAt: now, producer: producer, entries: records)
        try zip.addEntry(name: ArchiveManifest.fileName, data: try DocumentJSON.encoder().encode(manifest))
        try zip.finish()
        return manifest
    }
}

/// Exports one document (docs/FORMAT.md section 4, kind "document").
public enum DocumentArchiveWriter {
    /// Writes `snapshot` and its assets to `url` (created or truncated). On
    /// failure the partial file is removed and the error rethrown. Returns
    /// the manifest that was written as `archive.json`.
    @discardableResult
    public static func write(snapshot: DocumentSnapshot, assetData: AssetDataProvider, includeHistory: Bool = false,
                             to url: URL, producer: String, clock: Clock = SystemClock()) throws -> ArchiveManifest {
        let now = clock.now()
        do {
            let builder = try ArchiveBuilder(url: url, now: now)
            try builder.addDocument(snapshot, assetData: assetData, includeHistory: includeHistory, now: now)
            return try builder.finish(kind: .document, producer: producer, now: now)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

/// Exports a whole library: `library.json` plus every document (kind "library").
public enum LibraryArchiveWriter {
    public struct DocumentInput {
        public var snapshot: DocumentSnapshot
        public var assetData: AssetDataProvider
        public init(snapshot: DocumentSnapshot, assetData: @escaping AssetDataProvider) {
            self.snapshot = snapshot; self.assetData = assetData
        }
    }

    /// Documents are written sequentially, so the caller may load each
    /// snapshot lazily and only one document's assets are in flight at a time.
    @discardableResult
    public static func write(library: LibraryManifest, documents: [DocumentInput], includeHistory: Bool = false,
                             to url: URL, producer: String, clock: Clock = SystemClock()) throws -> ArchiveManifest {
        let now = clock.now()
        guard DocumentSchema.isReadable(library.schemaVersion) else { throw ArchiveError.unsupportedSchema(library.schemaVersion) }
        var seen = Set<DocumentID>()
        for d in documents {
            guard seen.insert(d.snapshot.document.id).inserted else {
                throw ArchiveError.duplicateEntry(ArchivePath.documentDirectory(d.snapshot.document.id))
            }
        }
        do {
            let builder = try ArchiveBuilder(url: url, now: now)
            for d in documents {
                try builder.addDocument(d.snapshot, assetData: d.assetData, includeHistory: includeHistory, now: now)
            }
            try builder.add(path: ArchiveManifest.libraryFileName, json: library)
            return try builder.finish(kind: .library, producer: producer, now: now)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
