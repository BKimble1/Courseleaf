import Foundation
import DocumentCore

// `archive.json` and the rules every entry path must satisfy (docs/FORMAT.md section 4).

public enum ArchiveKind: String, Codable, Hashable, Sendable {
    case document, library
}

/// One entry recorded in `archive.json`.
public struct ArchiveEntryRecord: Hashable, Codable, Sendable {
    public var path: String
    public var size: Int
    /// Lowercase hex SHA-256 of the entry's bytes.
    public var sha256: String
    public init(path: String, size: Int, sha256: String) { self.path = path; self.size = size; self.sha256 = sha256 }
}

public struct ArchiveManifest: Hashable, Codable, Sendable {
    public static let fileName = "archive.json"
    public static let libraryFileName = "library.json"
    public static let documentsDirectory = "documents"

    public var formatVersion: Int
    public var kind: ArchiveKind
    public var createdAt: Date
    /// e.g. "Courseleaf 1.0 (42)".
    public var producer: String
    public var entries: [ArchiveEntryRecord]
    /// Sum of every entry's `size`.
    public var totalSize: Int

    public init(formatVersion: Int = DocumentSchema.current, kind: ArchiveKind, createdAt: Date, producer: String,
                entries: [ArchiveEntryRecord], totalSize: Int? = nil) {
        self.formatVersion = formatVersion; self.kind = kind; self.createdAt = createdAt; self.producer = producer
        self.entries = entries; self.totalSize = totalSize ?? entries.reduce(0) { $0 + $1.size }
    }

    public func entry(for path: String) -> ArchiveEntryRecord? { entries.first { $0.path == path } }
}

/// `documents/<DocumentID>/manifest.json` inside an archive (same shape as a
/// package manifest, docs/FORMAT.md section 2). Keys of `pageFiles` are
/// `PageID` strings and keys of `assets` are `AssetID` strings so the JSON is
/// an object, not a key/value array.
public struct ArchivedDocumentManifest: Hashable, Codable, Sendable {
    public struct PageFile: Hashable, Codable, Sendable {
        /// Relative to the document directory: `pages/<PageID>-<RevisionID>.json`.
        public var file: String
        public var sha256: String
        public init(file: String, sha256: String) { self.file = file; self.sha256 = sha256 }
    }
    public var formatVersion: Int
    public var document: Document
    public var pageFiles: [String: PageFile]
    public var assets: [String: SourceAsset]
    public var committedAt: Date

    public init(formatVersion: Int = DocumentSchema.current, document: Document, pageFiles: [String: PageFile],
                assets: [String: SourceAsset], committedAt: Date) {
        self.formatVersion = formatVersion; self.document = document; self.pageFiles = pageFiles
        self.assets = assets; self.committedAt = committedAt
    }

    public static func pageFileName(pageID: PageID, revisionID: RevisionID) -> String { "pages/\(pageID)-\(revisionID).json" }
    public static func revisionFileName(_ id: RevisionID) -> String { "revisions/\(id).json" }
}

/// Resource limits applied before any archive content is trusted.
public struct ArchiveLimits: Hashable, Sendable {
    /// Maximum sum of entry sizes (declared and actual).
    public var totalBytes: Int
    /// Maximum `totalSize / archive file size`.
    public var expansionRatio: Double
    public var maxEntries: Int
    public var maxEntryBytes: Int

    public init(totalBytes: Int = 4 << 30, expansionRatio: Double = 200, maxEntries: Int = 50_000, maxEntryBytes: Int = 512 << 20) {
        self.totalBytes = totalBytes; self.expansionRatio = expansionRatio
        self.maxEntries = maxEntries; self.maxEntryBytes = maxEntryBytes
    }
    public static let `default` = ArchiveLimits()
}

/// Entry path rules. Paths are `/`-separated, relative, normalized and made of
/// printable characters; anything that could escape the extraction root is a
/// `pathTraversal`, everything else that is malformed is an `invalidPath`.
public enum ArchivePath {
    public static func validate(_ path: String) throws {
        guard !path.isEmpty else { throw ArchiveError.invalidPath(path) }
        let scalars = path.unicodeScalars
        if scalars.contains(where: { $0.value == 0 }) { throw ArchiveError.pathTraversal(path) }
        if scalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { throw ArchiveError.invalidPath(path) }
        if path.contains("\\") { throw ArchiveError.pathTraversal(path) }
        if path.hasPrefix("/") { throw ArchiveError.pathTraversal(path) }
        if isDriveLetterPath(path) { throw ArchiveError.pathTraversal(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for c in components {
            if c == ".." { throw ArchiveError.pathTraversal(path) }
            if c.isEmpty || c == "." { throw ArchiveError.invalidPath(path) }
            // Leading/trailing whitespace hides intent and differs across file systems.
            if c.first == " " || c.last == " " { throw ArchiveError.invalidPath(path) }
        }
    }

    /// Syntax rules plus "must be listed in archive.json".
    public static func validate(_ path: String, listedIn listed: Set<String>) throws {
        try validate(path)
        guard listed.contains(path) else { throw ArchiveError.unlistedEntry(path) }
    }

    public static func isValid(_ path: String) -> Bool { (try? validate(path)) != nil }

    private static func isDriveLetterPath(_ path: String) -> Bool {
        let s = Array(path.utf8)
        guard s.count >= 2, s[1] == UInt8(ascii: ":") else { return false }
        return (s[0] >= UInt8(ascii: "A") && s[0] <= UInt8(ascii: "Z")) || (s[0] >= UInt8(ascii: "a") && s[0] <= UInt8(ascii: "z"))
    }

    // MARK: Layout helpers

    /// Where a document's files live inside the archive.
    public static func documentDirectory(_ id: DocumentID) -> String { "\(ArchiveManifest.documentsDirectory)/\(id)" }

    /// Parses `documents/<DocumentID>/<rest>`; nil when the path is not inside the documents tree.
    static func documentComponent(of path: String) -> (id: DocumentID, rest: String)? {
        let parts = path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == ArchiveManifest.documentsDirectory,
              let id = DocumentID(uuidString: String(parts[1])), id.description == parts[1] else { return nil }
        return (id, String(parts[2]))
    }

    static func isHexDigest(_ s: Substring) -> Bool {
        s.count == 64 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}
