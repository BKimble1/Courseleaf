import Foundation
import DocumentCore

/// Relative paths inside a document package (docs/FORMAT.md section 2) and the library (section 1).
public enum PackageLayout {
    public static let packageExtension = "courseleafdoc"
    public static let manifestFile = "manifest.json"
    public static let lkgManifestFile = "manifest.lkg.json"
    public static let pagesDirectory = "pages"
    public static let assetsDirectory = "assets"
    public static let revisionsDirectory = "revisions"
    public static let tmpDirectory = "tmp"

    public static func packageName(for id: DocumentID) -> String { "\(id.rawValue.uuidString).\(packageExtension)" }
    public static func documentID(fromPackageName name: String) -> DocumentID? {
        guard name.hasSuffix(".\(packageExtension)") else { return nil }
        return DocumentID(uuidString: String(name.dropLast(packageExtension.count + 1)))
    }
    /// `pages/<PageID>-<RevisionID>.json`
    public static func pageFile(pageID: PageID, revisionID: RevisionID) -> String {
        "\(pagesDirectory)/\(pageID.rawValue.uuidString)-\(revisionID.rawValue.uuidString).json"
    }
    /// Parses `<PageID>-<RevisionID>.json` (a file name inside `pages/`).
    public static func parsePageFileName(_ name: String) -> (pageID: PageID, revisionID: RevisionID)? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = name.dropLast(5)
        guard stem.count == 73 else { return nil }
        let pageID = PageID(uuidString: String(stem.prefix(36)))
        let revisionID = RevisionID(uuidString: String(stem.suffix(36)))
        guard let pageID, let revisionID else { return nil }
        return (pageID, revisionID)
    }
    /// `revisions/<RevisionID>.json`
    public static func revisionFile(_ id: RevisionID) -> String { "\(revisionsDirectory)/\(id.rawValue.uuidString).json" }
    /// `assets/<xx>/<sha256>.<ext>` (same as `SourceAsset.relativePath`).
    public static func assetFile(sha256: String, mediaType: AssetMediaType) -> String {
        "\(assetsDirectory)/\(sha256.prefix(2))/\(sha256).\(mediaType.fileExtension)"
    }
}

/// Library-level layout (docs/FORMAT.md section 1).
public enum LibraryLayout {
    public static let manifestFile = "library.json"
    public static let lkgManifestFile = "library.lkg.json"
    public static let documentsDirectory = "Documents"
    public static let trashDirectory = "Trash"
    public static let catalogDirectory = "Catalog"
    public static let previewsDirectory = "Previews"
    public static let stagingDirectory = "Staging"
}

/// One entry of `manifest.json`'s `pageFiles` table.
public struct PageFileEntry: Hashable, Codable, Sendable {
    /// Package-relative path, e.g. `pages/<PageID>-<RevisionID>.json`.
    public var file: String
    /// Lowercase hex SHA-256 of the page file bytes.
    public var sha256: String
    public init(file: String, sha256: String) { self.file = file; self.sha256 = sha256 }
    public var revisionID: RevisionID? {
        PackageLayout.parsePageFileName(String(file.split(separator: "/").last ?? ""))?.revisionID
    }
}

/// `manifest.json` (docs/FORMAT.md section 2). Dictionaries keyed by
/// identifiers are encoded as JSON objects keyed by the UUID string.
public struct PackageManifest: Hashable, Sendable {
    public var formatVersion: Int
    public var document: Document
    public var pageFiles: [PageID: PageFileEntry]
    public var assets: [AssetID: SourceAsset]
    public var committedAt: Date

    public init(formatVersion: Int = DocumentSchema.current, document: Document, pageFiles: [PageID: PageFileEntry],
                assets: [AssetID: SourceAsset], committedAt: Date) {
        self.formatVersion = formatVersion; self.document = document; self.pageFiles = pageFiles
        self.assets = assets; self.committedAt = committedAt
    }

    public func encoded() throws -> Data { try DocumentJSON.encoder().encode(self) }
    public static func decode(_ data: Data) throws -> PackageManifest { try DocumentJSON.decoder().decode(PackageManifest.self, from: data) }

    /// Reads only `formatVersion` so a newer-than-supported manifest can be
    /// recognized before this build tries to decode fields it does not know.
    public struct Header: Codable, Hashable, Sendable {
        public var formatVersion: Int
    }
    public static func decodeHeader(_ data: Data) throws -> Header { try DocumentJSON.decoder().decode(Header.self, from: data) }

    /// A lightweight read for library listings: the document plus the page file
    /// count, without loading any page content.
    public struct Listing: Hashable, Sendable {
        public var formatVersion: Int
        public var document: Document
        public var pageCount: Int
        public var committedAt: Date
    }
}

extension PackageManifest: Codable {
    private enum CodingKeys: String, CodingKey { case formatVersion, document, pageFiles, assets, committedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        document = try c.decode(Document.self, forKey: .document)
        committedAt = try c.decode(Date.self, forKey: .committedAt)
        let rawPages = try c.decode([String: PageFileEntry].self, forKey: .pageFiles)
        var pages: [PageID: PageFileEntry] = [:]
        for (key, value) in rawPages {
            guard let id = PageID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(forKey: .pageFiles, in: c, debugDescription: "Invalid page id '\(key)'")
            }
            pages[id] = value
        }
        pageFiles = pages
        let rawAssets = try c.decodeIfPresent([String: SourceAsset].self, forKey: .assets) ?? [:]
        var assetTable: [AssetID: SourceAsset] = [:]
        for (key, value) in rawAssets {
            guard let id = AssetID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(forKey: .assets, in: c, debugDescription: "Invalid asset id '\(key)'")
            }
            assetTable[id] = value
        }
        assets = assetTable
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(document, forKey: .document)
        try c.encode(committedAt, forKey: .committedAt)
        var rawPages: [String: PageFileEntry] = [:]
        for (id, entry) in pageFiles { rawPages[id.rawValue.uuidString] = entry }
        try c.encode(rawPages, forKey: .pageFiles)
        var rawAssets: [String: SourceAsset] = [:]
        for (id, asset) in assets { rawAssets[id.rawValue.uuidString] = asset }
        try c.encode(rawAssets, forKey: .assets)
    }
}

// MARK: - Schema migration

/// Rewrites a manifest from an older readable schema to `DocumentSchema.current`.
/// Version 1 is the only version so far, so the migration chain is empty; a
/// manifest declaring a newer version is refused with `unsupportedSchema`
/// (docs/FORMAT.md section 5).
public enum SchemaMigrator {
    public struct Migration: Sendable {
        public let from: Int
        public let to: Int
        public let apply: @Sendable (PackageManifest) throws -> PackageManifest
        public init(from: Int, to: Int, apply: @escaping @Sendable (PackageManifest) throws -> PackageManifest) {
            self.from = from; self.to = to; self.apply = apply
        }
    }

    /// Registered migrations, ordered by `from`. Empty while the schema is at version 1.
    public static let migrations: [Migration] = []

    /// Throws `unsupportedSchema` for versions this build cannot read.
    public static func checkReadable(_ version: Int) throws {
        guard DocumentSchema.isReadable(version) else { throw PersistenceError.unsupportedSchema(version: version) }
    }

    public static func migrate(_ manifest: PackageManifest) throws -> PackageManifest {
        try checkReadable(manifest.formatVersion)
        var current = manifest
        while current.formatVersion < DocumentSchema.current {
            guard let step = migrations.first(where: { $0.from == current.formatVersion }) else {
                throw PersistenceError.unsupportedSchema(version: current.formatVersion)
            }
            current = try step.apply(current)
            current.formatVersion = step.to
        }
        current.document.schemaVersion = current.formatVersion
        return current
    }
}
