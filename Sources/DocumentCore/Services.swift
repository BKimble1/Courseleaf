import Foundation

// Shared service-level value types used by Persistence, Catalog, Workspace and
// the app so the modules agree without depending on each other.

/// Durable save state shown in the editor. `.saved` is only reported after the
/// manifest replacement and directory sync completed.
public enum SaveStatus: Hashable, Sendable {
    case unsaved(pendingChanges: Int)
    case saving
    case saved(at: Date, latency: TimeInterval)
    case failed(message: String, retryable: Bool)

    public var isDurable: Bool { if case .saved = self { return true } else { return false } }
}

/// How tape (answer covers) is treated when exporting.
public enum TapeExportPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Draw tape exactly as it is on screen: hidden answers stay covered, revealed ones show.
    case asShown
    /// Draw every tape as covering, regardless of its revealed state.
    case coverAll
    /// Omit tape so every answer is visible.
    case revealAll
}

public enum ExportFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case pdf, png, jpeg, archive
}

public struct ExportOptions: Hashable, Sendable {
    public var format: ExportFormat
    /// nil exports every live page in order.
    public var pageIDs: [PageID]?
    public var tape: TapeExportPolicy
    /// Raster scale for ink (and images) relative to page points, e.g. 2 = 144 dpi.
    public var inkRasterScale: Double
    /// Include the source PDF's vector content (text stays searchable) rather than a raster snapshot.
    public var preserveSourceVectors: Bool
    public init(format: ExportFormat, pageIDs: [PageID]? = nil, tape: TapeExportPolicy = .asShown,
                inkRasterScale: Double = 2, preserveSourceVectors: Bool = true) {
        self.format = format; self.pageIDs = pageIDs; self.tape = tape
        self.inkRasterScale = inkRasterScale; self.preserveSourceVectors = preserveSourceVectors
    }
}

// MARK: - Search and recognition

public enum SearchRecordKind: String, Codable, Hashable, Sendable, CaseIterable {
    case title, typed, pdfText, recognized
}

/// One indexable text fragment tied to a page revision. Bounds are in page
/// space so a hit can be highlighted; `confidence` is only meaningful for
/// `recognized` records (0...1) and is never shown as a precision claim.
public struct SearchRecord: Hashable, Codable, Sendable {
    public var documentID: DocumentID
    public var pageID: PageID
    public var revisionID: RevisionID
    public var kind: SearchRecordKind
    public var text: String
    public var bounds: PageRect?
    public var language: String
    public var confidence: Double?
    public init(documentID: DocumentID, pageID: PageID, revisionID: RevisionID, kind: SearchRecordKind, text: String,
                bounds: PageRect? = nil, language: String = "en", confidence: Double? = nil) {
        self.documentID = documentID; self.pageID = pageID; self.revisionID = revisionID; self.kind = kind
        self.text = text; self.bounds = bounds; self.language = language; self.confidence = confidence
    }
}

/// Per-page derived-data state, so search can distinguish "no matches" from
/// "not yet indexed".
public enum IndexingState: String, Codable, Hashable, Sendable {
    case notIndexed, queued, indexed, failed, notApplicable
}

public struct PageIndexStatus: Hashable, Codable, Sendable {
    public var pageID: PageID
    public var revisionID: RevisionID
    public var pdfText: IndexingState
    public var recognized: IndexingState
    public var lastError: String?
    public init(pageID: PageID, revisionID: RevisionID, pdfText: IndexingState, recognized: IndexingState, lastError: String? = nil) {
        self.pageID = pageID; self.revisionID = revisionID; self.pdfText = pdfText; self.recognized = recognized; self.lastError = lastError
    }
}

// MARK: - Platform inspection hooks

/// Geometry of one PDF page as read from a file, in PDF user space.
public struct PDFPageInfo: Hashable, Codable, Sendable {
    public var index: Int
    public var mediaBox: PageRect
    public var cropBox: PageRect
    public var rotation: PageRotation
    public var hasText: Bool?
    public init(index: Int, mediaBox: PageRect, cropBox: PageRect, rotation: PageRotation, hasText: Bool? = nil) {
        self.index = index; self.mediaBox = mediaBox; self.cropBox = cropBox; self.rotation = rotation; self.hasText = hasText
    }
    public func source(assetID: AssetID) -> PDFPageSource {
        PDFPageSource(assetID: assetID, pageIndex: index, mediaBox: mediaBox, cropBox: cropBox, rotation: rotation)
    }
}

public struct PDFFileInfo: Hashable, Codable, Sendable {
    public var pageCount: Int
    public var pages: [PDFPageInfo]
    public var isEncrypted: Bool
    public var outlineTitles: [String]
    public init(pageCount: Int, pages: [PDFPageInfo], isEncrypted: Bool = false, outlineTitles: [String] = []) {
        self.pageCount = pageCount; self.pages = pages; self.isEncrypted = isEncrypted; self.outlineTitles = outlineTitles
    }
}

public enum PDFInspectionError: Error, Equatable {
    case notAPDF, encrypted, corrupt(String), tooLarge(bytes: Int, limit: Int), cancelled
}

/// Reads page geometry from a PDF without rendering it. The app implements
/// this with PDFKit; `Fixtures.MinimalPDFInspector` parses the uncompressed
/// PDFs the fixture writer produces so import logic is testable on Linux.
public protocol PDFInspecting: Sendable {
    func inspect(fileAt url: URL) throws -> PDFFileInfo
}

public struct ImageInfo: Hashable, Codable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var mediaType: AssetMediaType
    public init(pixelWidth: Int, pixelHeight: Int, mediaType: AssetMediaType) {
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.mediaType = mediaType
    }
}

public enum ImageInspectionError: Error, Equatable { case unsupported, corrupt }

/// Reads pixel dimensions from PNG/JPEG headers. A portable implementation
/// lives in `Fixtures.ImageHeaderInspector`; the app may use ImageIO.
public protocol ImageInspecting: Sendable {
    func inspect(data: Data) throws -> ImageInfo
}

/// Injected time source so save coalescing and timestamps are testable.
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Deterministic clock for tests.
public final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(start: Date = Date(timeIntervalSince1970: 1_757_600_000)) { current = start }
    public func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    public func advance(by seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    public func set(_ date: Date) { lock.lock(); current = date; lock.unlock() }
}
