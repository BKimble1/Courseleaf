import Foundation

/// The complete in-memory state of one open document: manifest-level
/// metadata, every live and deleted page, and the asset table. The editing
/// layer mutates a snapshot through commands; Persistence commits the changed
/// parts. Snapshots are plain values, so undo can keep cheap copies.
public struct DocumentSnapshot: Hashable, Sendable {
    public var document: Document
    public var pages: [PageID: Page]
    public var assets: [AssetID: SourceAsset]
    public var revisions: [RevisionID: Revision]

    public init(document: Document, pages: [PageID: Page], assets: [AssetID: SourceAsset] = [:], revisions: [RevisionID: Revision] = [:]) {
        self.document = document; self.pages = pages; self.assets = assets; self.revisions = revisions
    }

    /// Live pages in document order. Missing pages are skipped; `validate()` reports them.
    public var orderedPages: [Page] { document.pageIDs.compactMap { pages[$0] } }
    public func page(_ id: PageID) -> Page? { pages[id] }
    public func pageIndex(_ id: PageID) -> Int? { document.pageIDs.firstIndex(of: id) }
    public var headRevision: Revision? { revisions[document.revisionHead] }

    /// Assets referenced by any live page, deleted page or the document.
    public var referencedAssetIDs: Set<AssetID> {
        var ids = Set<AssetID>()
        for p in pages.values { ids.formUnion(p.referencedAssetIDs) }
        for d in document.deletedPages { ids.formUnion(d.page.referencedAssetIDs) }
        return ids
    }

    /// Creates a new notebook with `pageCount` template pages.
    public static func newNotebook(title: String, folderID: FolderID? = nil, template: PaperTemplate = .lined,
                                   pageSize: PageSize = .letter, pageCount: Int = 1, kind: DocumentKind = .notebook,
                                   cover: CoverStyle = .default, now: Date) -> DocumentSnapshot {
        precondition(pageCount >= 1)
        let revision = Revision(parentIDs: [], sequence: 1, createdAt: now, changedPageIDs: [], summary: "Created")
        var pages: [PageID: Page] = [:]
        var ids: [PageID] = []
        for _ in 0..<pageCount {
            let page = Page(size: pageSize, background: .template(template), revisionID: revision.id, createdAt: now, modifiedAt: now)
            pages[page.id] = page; ids.append(page.id)
        }
        var rev = revision; rev.changedPageIDs = ids
        let doc = Document(kind: kind, title: title, folderID: folderID, cover: cover, defaultTemplate: template,
                           defaultPageSize: pageSize, pageIDs: ids, revisionHead: rev.id, createdAt: now, modifiedAt: now)
        return DocumentSnapshot(document: doc, pages: pages, assets: [:], revisions: [rev.id: rev])
    }

    // MARK: Validation

    public enum ValidationIssue: Hashable, Sendable, CustomStringConvertible {
        case unsupportedSchema(Int)
        case duplicatePageID(PageID)
        case missingPage(PageID)
        case orphanPage(PageID)
        case duplicateObjectID(ObjectID, PageID)
        case missingAsset(AssetID, PageID?)
        case missingRevisionHead(RevisionID)
        case invalidPageSize(PageID)
        case invalidObjectFrame(ObjectID, PageID)
        case reviewItemPageMissing(ReviewItemID, PageID)

        public var description: String {
            switch self {
            case .unsupportedSchema(let v): return "unsupported schema version \(v)"
            case .duplicatePageID(let p): return "duplicate page id \(p)"
            case .missingPage(let p): return "page \(p) listed but has no content"
            case .orphanPage(let p): return "page \(p) has content but is not listed"
            case .duplicateObjectID(let o, let p): return "duplicate object \(o) on page \(p)"
            case .missingAsset(let a, let p): return "asset \(a) referenced by page \(p.map(\.description) ?? "-") is missing"
            case .missingRevisionHead(let r): return "revision head \(r) is not present"
            case .invalidPageSize(let p): return "page \(p) has an invalid size"
            case .invalidObjectFrame(let o, let p): return "object \(o) on page \(p) has a non-finite frame"
            case .reviewItemPageMissing(let r, let p): return "review item \(r) points at missing page \(p)"
            }
        }
    }

    /// Structural validation of the snapshot. Missing assets are reported
    /// against the referencing page; the caller decides whether the asset
    /// file exists on disk. An empty result means the snapshot is coherent.
    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if !DocumentSchema.isReadable(document.schemaVersion) { issues.append(.unsupportedSchema(document.schemaVersion)) }
        var seen = Set<PageID>()
        for id in document.pageIDs {
            if !seen.insert(id).inserted { issues.append(.duplicatePageID(id)) }
            if pages[id] == nil { issues.append(.missingPage(id)) }
        }
        let deletedIDs = Set(document.deletedPages.map(\.id))
        for id in pages.keys where !seen.contains(id) && !deletedIDs.contains(id) { issues.append(.orphanPage(id)) }
        for page in pages.values {
            if !page.size.isValid { issues.append(.invalidPageSize(page.id)) }
            var objectIDs = Set<ObjectID>()
            for o in page.objects {
                if !objectIDs.insert(o.id).inserted { issues.append(.duplicateObjectID(o.id, page.id)) }
                if !o.frame.isFinite || !o.rotation.isFinite { issues.append(.invalidObjectFrame(o.id, page.id)) }
            }
            for a in page.referencedAssetIDs where assets[a] == nil { issues.append(.missingAsset(a, page.id)) }
        }
        if revisions[document.revisionHead] == nil { issues.append(.missingRevisionHead(document.revisionHead)) }
        let livePages = Set(document.pageIDs)
        for item in document.reviewItems where !livePages.contains(item.pageID) && !deletedIDs.contains(item.pageID) {
            issues.append(.reviewItemPageMissing(item.id, item.pageID))
        }
        return issues.sorted { $0.description < $1.description }
    }
}

/// Bytes for a new immutable asset that the next commit must write before the
/// manifest references it. `data` is hashed by Persistence; the resulting
/// `SourceAsset.sha256` must match the record the caller placed in the snapshot.
public struct PendingAsset: Hashable, Sendable {
    public var asset: SourceAsset
    public var data: Data
    public init(asset: SourceAsset, data: Data) { self.asset = asset; self.data = data }

    /// Builds a record + payload pair, computing the digest.
    public static func make(data: Data, mediaType: AssetMediaType, originalFileName: String? = nil, pageCount: Int? = nil, now: Date) -> PendingAsset {
        let asset = SourceAsset(sha256: SHA256.hexDigest(data), mediaType: mediaType, byteCount: data.count,
                                originalFileName: originalFileName, pageCount: pageCount, importedAt: now)
        return PendingAsset(asset: asset, data: data)
    }
}

/// What changed since the last commit. Persistence writes only these pages
/// and assets, never the whole document, so a single Pencil stroke does not
/// rewrite a 300-page notebook.
public struct ChangeSet: Hashable, Sendable {
    public var changedPageIDs: Set<PageID>
    public var documentChanged: Bool
    public var newAssets: [PendingAsset]
    public init(changedPageIDs: Set<PageID> = [], documentChanged: Bool = false, newAssets: [PendingAsset] = []) {
        self.changedPageIDs = changedPageIDs; self.documentChanged = documentChanged; self.newAssets = newAssets
    }
    public var isEmpty: Bool { changedPageIDs.isEmpty && !documentChanged && newAssets.isEmpty }
    public mutating func merge(_ other: ChangeSet) {
        changedPageIDs.formUnion(other.changedPageIDs)
        documentChanged = documentChanged || other.documentChanged
        let known = Set(newAssets.map(\.asset.id))
        newAssets += other.newAssets.filter { !known.contains($0.asset.id) }
    }
    public static let empty = ChangeSet()
}

// MARK: - JSON coding conventions

public enum DocumentJSON {
    /// Deterministic encoder: sorted keys, ISO-8601 dates with fractional seconds.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer(); try c.encode(ISO8601.string(from: date))
        }
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer(); let s = try c.decode(String.self)
            guard let date = ISO8601.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date '\(s)'")
            }
            return date
        }
        return d
    }
}

public enum ISO8601 {
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }
    public static func string(from date: Date) -> String { formatter(fractional: true).string(from: date) }
    public static func date(from string: String) -> Date? {
        formatter(fractional: true).date(from: string) ?? formatter(fractional: false).date(from: string)
    }
}
