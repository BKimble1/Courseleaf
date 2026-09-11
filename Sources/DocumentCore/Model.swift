import Foundation

// The persisted document model. See docs/FORMAT.md for the on-disk layout and
// docs/ARCHITECTURE.md for ownership rules. All types are value types and
// Codable with stable JSON keys; adding a field must be backwards compatible
// (optional or defaulted) or bump `DocumentSchema.current`.

public enum DocumentSchema {
    /// Current native schema version. Bump only with a migration in Persistence.
    public static let current = 1
    /// Oldest schema this build can read.
    public static let oldestReadable = 1
    public static func isReadable(_ version: Int) -> Bool { version >= oldestReadable && version <= current }
}

public enum DocumentKind: String, Codable, Hashable, Sendable {
    case notebook
    /// Quick capture note created without choosing a folder; shown in the inbox until filed.
    case quickNote
}

// MARK: - Paper and covers

public enum PaperKind: String, Codable, Hashable, Sendable, CaseIterable {
    case blank, lined, grid, dotted, cornell, engineering
}

/// Original paper template description. Spacing values are page points so a
/// template renders identically at any zoom or on export (no screen pixels).
public struct PaperTemplate: Hashable, Codable, Sendable {
    public var kind: PaperKind
    /// Line pitch for lined/cornell, cell size for grid/dotted/engineering, in points.
    public var spacing: Double
    public var lineColor: RGBAColor
    public var paperColor: RGBAColor
    /// Top margin (points) before the first rule; also used as the Cornell header height.
    public var topMargin: Double
    /// Left margin (points); the Cornell cue column width and the engineering left rule.
    public var leftMargin: Double

    public init(kind: PaperKind, spacing: Double = 24, lineColor: RGBAColor = RGBAColor(hex: "#B8C0CC")!,
                paperColor: RGBAColor = .white, topMargin: Double = 72, leftMargin: Double = 0) {
        self.kind = kind; self.spacing = spacing; self.lineColor = lineColor
        self.paperColor = paperColor; self.topMargin = topMargin; self.leftMargin = leftMargin
    }
    public static let blank = PaperTemplate(kind: .blank, spacing: 0, topMargin: 0)
    /// College-ruled equivalent: 7.1 mm ≈ 20.2 pt; we use 20 pt.
    public static let lined = PaperTemplate(kind: .lined, spacing: 20, topMargin: 72, leftMargin: 0)
    public static let grid = PaperTemplate(kind: .grid, spacing: 18, topMargin: 0, leftMargin: 0)
    public static let dotted = PaperTemplate(kind: .dotted, spacing: 18, topMargin: 0, leftMargin: 0)
    public static let cornell = PaperTemplate(kind: .cornell, spacing: 20, topMargin: 60, leftMargin: 160)
    /// Engineering pad: 0.2 inch (14.4 pt) light grid with a heavier left margin rule.
    public static let engineering = PaperTemplate(kind: .engineering, spacing: 14.4,
                                                  lineColor: RGBAColor(hex: "#A9CFB5")!,
                                                  paperColor: RGBAColor(hex: "#F5F7EE")!, topMargin: 54, leftMargin: 54)
    public static func preset(_ kind: PaperKind) -> PaperTemplate {
        switch kind {
        case .blank: return .blank
        case .lined: return .lined
        case .grid: return .grid
        case .dotted: return .dotted
        case .cornell: return .cornell
        case .engineering: return .engineering
        }
    }
}

/// Original notebook cover: a named palette color plus a simple pattern. The
/// app draws covers procedurally; there are no licensed cover images.
public struct CoverStyle: Hashable, Codable, Sendable {
    public enum Palette: String, Codable, Hashable, Sendable, CaseIterable {
        case slate, moss, clay, ocean, plum, sand, ink, mint
    }
    public enum Pattern: String, Codable, Hashable, Sendable, CaseIterable {
        case plain, bands, dots, weave
    }
    public var palette: Palette
    public var pattern: Pattern
    public var showsTitle: Bool
    public init(palette: Palette = .slate, pattern: Pattern = .plain, showsTitle: Bool = true) {
        self.palette = palette; self.pattern = pattern; self.showsTitle = showsTitle
    }
    public static let `default` = CoverStyle()
}

// MARK: - Assets

public enum AssetMediaType: String, Codable, Hashable, Sendable {
    case pdf = "application/pdf"
    case png = "image/png"
    case jpeg = "image/jpeg"
    /// Serialized ink drawing for the engine named in the ink layer.
    case inkDrawing = "application/x-courseleaf-ink"
    case other = "application/octet-stream"

    public var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .png: return "png"
        case .jpeg: return "jpg"
        case .inkDrawing: return "ink"
        case .other: return "bin"
        }
    }
    public init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "pdf": self = .pdf
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "ink": self = .inkDrawing
        default: self = .other
        }
    }
}

/// An immutable content file inside a document package, addressed by SHA-256.
/// Original imported PDFs and images are stored byte-for-byte unmodified.
public struct SourceAsset: Hashable, Codable, Sendable, Identifiable {
    public var id: AssetID
    /// Lowercase hex SHA-256 of the file contents; also the on-disk file name.
    public var sha256: String
    public var mediaType: AssetMediaType
    public var byteCount: Int
    public var originalFileName: String?
    /// For PDFs: number of pages, captured at import.
    public var pageCount: Int?
    public var importedAt: Date

    public init(id: AssetID = AssetID(), sha256: String, mediaType: AssetMediaType, byteCount: Int,
                originalFileName: String? = nil, pageCount: Int? = nil, importedAt: Date) {
        self.id = id; self.sha256 = sha256; self.mediaType = mediaType; self.byteCount = byteCount
        self.originalFileName = originalFileName; self.pageCount = pageCount; self.importedAt = importedAt
    }
    /// Relative path of the asset file inside a package: `assets/<first two hex>/<sha256>.<ext>`.
    public var relativePath: String { "assets/\(sha256.prefix(2))/\(sha256).\(mediaType.fileExtension)" }
}

// MARK: - Page background

/// Geometry of an imported PDF page captured at import time so page-space
/// mapping is deterministic and testable without PDFKit. Boxes are in PDF
/// user space (origin bottom-left, y up), as read from the file.
public struct PDFPageSource: Hashable, Codable, Sendable {
    public var assetID: AssetID
    /// Zero-based page index in the source PDF.
    public var pageIndex: Int
    public var mediaBox: PageRect
    /// Effective CropBox (defaults to MediaBox when absent), intersected with MediaBox.
    public var cropBox: PageRect
    /// The page's /Rotate value normalized to 0/90/180/270.
    public var rotation: PageRotation
    public init(assetID: AssetID, pageIndex: Int, mediaBox: PageRect, cropBox: PageRect, rotation: PageRotation) {
        self.assetID = assetID; self.pageIndex = pageIndex; self.mediaBox = mediaBox
        self.cropBox = cropBox; self.rotation = rotation
    }
    /// Size of the visible page after rotation, in points (page-space size).
    public var displaySize: PageSize {
        let s = PageSize(width: cropBox.width, height: cropBox.height)
        return rotation.swapsWidthAndHeight ? s.swapped : s
    }
}

public enum PageBackground: Hashable, Codable, Sendable {
    case template(PaperTemplate)
    case pdf(PDFPageSource)
    /// A full-page image (scan or photo import). The asset is fitted to the page size.
    case image(AssetID)

    public var assetID: AssetID? {
        switch self {
        case .template: return nil
        case .pdf(let src): return src.assetID
        case .image(let id): return id
        }
    }
    public var isImported: Bool { if case .template = self { return false } else { return true } }
}

// MARK: - Ink layers and canvas objects

public struct InkLayer: Hashable, Codable, Sendable, Identifiable {
    public var id: InkLayerID
    public var engine: InkEngineIdentifier
    /// Immutable drawing blob; nil when the layer has never been drawn on.
    public var dataAssetID: AssetID?
    public var isVisible: Bool
    public init(id: InkLayerID = InkLayerID(), engine: InkEngineIdentifier = .pencilKit, dataAssetID: AssetID? = nil, isVisible: Bool = true) {
        self.id = id; self.engine = engine; self.dataAssetID = dataAssetID; self.isVisible = isVisible
    }
}

public enum FontWeight: String, Codable, Hashable, Sendable, CaseIterable { case regular, medium, semibold, bold }
public enum FontDesign: String, Codable, Hashable, Sendable, CaseIterable { case standard, serif, monospaced, rounded }
public enum TextAlignment: String, Codable, Hashable, Sendable, CaseIterable { case leading, center, trailing }

public struct TextContent: Hashable, Codable, Sendable {
    public var text: String
    public var fontSize: Double
    public var weight: FontWeight
    public var design: FontDesign
    public var alignment: TextAlignment
    public var color: RGBAColor
    public init(text: String, fontSize: Double = 16, weight: FontWeight = .regular, design: FontDesign = .standard,
                alignment: TextAlignment = .leading, color: RGBAColor = .black) {
        self.text = text; self.fontSize = fontSize; self.weight = weight; self.design = design
        self.alignment = alignment; self.color = color
    }
}

public struct ImageContent: Hashable, Codable, Sendable {
    public var assetID: AssetID
    /// Visible sub-rectangle of the source image in unit coordinates (crop). Default: whole image.
    public var crop: PageRect
    public var opacity: Double
    public init(assetID: AssetID, crop: PageRect = .unit, opacity: Double = 1) {
        self.assetID = assetID; self.crop = crop; self.opacity = opacity
    }
}

public enum ShapeKind: String, Codable, Hashable, Sendable, CaseIterable { case line, arrow, rectangle, ellipse }

public struct ShapeContent: Hashable, Codable, Sendable {
    public var kind: ShapeKind
    public var strokeColor: RGBAColor
    public var strokeWidth: Double
    public var fillColor: RGBAColor?
    /// For line/arrow: endpoints in unit coordinates of the object frame.
    public var start: PagePoint
    public var end: PagePoint
    public init(kind: ShapeKind, strokeColor: RGBAColor = .black, strokeWidth: Double = 2, fillColor: RGBAColor? = nil,
                start: PagePoint = PagePoint(x: 0, y: 0), end: PagePoint = PagePoint(x: 1, y: 1)) {
        self.kind = kind; self.strokeColor = strokeColor; self.strokeWidth = strokeWidth
        self.fillColor = fillColor; self.start = start; self.end = end
    }
}

/// Opaque cover used to hide an answer for recall practice. Revealed state is
/// part of the document so it survives relaunch; export chooses whether tape
/// is drawn (see `TapeExportPolicy`).
public struct TapeContent: Hashable, Codable, Sendable {
    public var color: RGBAColor
    public var isRevealed: Bool
    public var label: String?
    public init(color: RGBAColor = RGBAColor(hex: "#F2C94C")!, isRevealed: Bool = false, label: String? = nil) {
        self.color = color; self.isRevealed = isRevealed; self.label = label
    }
}

public enum ObjectContent: Hashable, Codable, Sendable {
    case text(TextContent)
    case image(ImageContent)
    case shape(ShapeContent)
    case tape(TapeContent)

    public var kind: ObjectKind {
        switch self {
        case .text: return .text
        case .image: return .image
        case .shape: return .shape
        case .tape: return .tape
        }
    }
    public var assetID: AssetID? { if case .image(let c) = self { return c.assetID } else { return nil } }
}

public enum ObjectKind: String, Codable, Hashable, Sendable, CaseIterable { case text, image, shape, tape }

/// A typed object placed on a page. Objects live above ink in the composite
/// order except images, which render beneath ink (see docs/ARCHITECTURE.md
/// "Compositing order"). Z-order within each band is the page's array order.
public struct CanvasObject: Hashable, Codable, Sendable, Identifiable {
    public var id: ObjectID
    /// Axis-aligned frame in page points before `rotation` is applied about the frame center.
    public var frame: PageRect
    /// Rotation in radians, clockwise on screen (y-down space), about the frame center.
    public var rotation: Double
    public var isLocked: Bool
    public var content: ObjectContent
    public var createdAt: Date
    public init(id: ObjectID = ObjectID(), frame: PageRect, rotation: Double = 0, isLocked: Bool = false,
                content: ObjectContent, createdAt: Date) {
        self.id = id; self.frame = frame; self.rotation = rotation; self.isLocked = isLocked
        self.content = content; self.createdAt = createdAt
    }
    public var kind: ObjectKind { content.kind }
    /// Transform from unit-square object space to page space (frame + rotation).
    public var transform: PageTransform {
        PageTransform.scale(x: frame.width, y: frame.height)
            .concatenating(.translation(x: frame.minX, y: frame.minY))
            .concatenating(.rotation(radians: rotation, about: frame.center))
    }
    /// Axis-aligned bounds in page space including rotation.
    public var bounds: PageRect { rotation == 0 ? frame.standardized : PageRect.unit.applying(transform) }
}

// MARK: - Problem Pages and review

public enum ProblemStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case unfinished, checkAgain, understood
}

/// Student-defined structure for a Problem Page. Every field is optional in
/// use; the student decides what each region means. No recognition required.
public struct ProblemMetadata: Hashable, Codable, Sendable {
    public var title: String
    public var sourceReference: String?
    public var given: String?
    public var find: String?
    /// Region of the page holding the result, in page points.
    public var resultRegion: PageRect?
    public var status: ProblemStatus
    public init(title: String, sourceReference: String? = nil, given: String? = nil, find: String? = nil,
                resultRegion: PageRect? = nil, status: ProblemStatus = .unfinished) {
        self.title = title; self.sourceReference = sourceReference; self.given = given; self.find = find
        self.resultRegion = resultRegion; self.status = status
    }
}

public enum ReviewState: String, Codable, Hashable, Sendable { case pending, reviewed }

public struct ReviewEvent: Hashable, Codable, Sendable {
    public enum Action: String, Codable, Hashable, Sendable { case added, revealed, hidden, markedReviewed, reopened, promptEdited }
    public var action: Action
    public var at: Date
    public init(action: Action, at: Date) { self.action = action; self.at = at }
}

/// A page or rectangular region queued for later review. Stored inside the
/// document so it survives native export/import and recovery. The course-level
/// queue is a catalog query over all documents in a course folder.
public struct ReviewItem: Hashable, Codable, Sendable, Identifiable {
    public var id: ReviewItemID
    public var pageID: PageID
    /// nil means the whole page.
    public var region: PageRect?
    public var prompt: String?
    /// Tape object covering the answer, if the student added one for this item.
    public var answerTapeID: ObjectID?
    public var state: ReviewState
    public var createdAt: Date
    public var lastReviewedAt: Date?
    public var history: [ReviewEvent]
    public init(id: ReviewItemID = ReviewItemID(), pageID: PageID, region: PageRect? = nil, prompt: String? = nil,
                answerTapeID: ObjectID? = nil, state: ReviewState = .pending, createdAt: Date,
                lastReviewedAt: Date? = nil, history: [ReviewEvent] = []) {
        self.id = id; self.pageID = pageID; self.region = region; self.prompt = prompt; self.answerTapeID = answerTapeID
        self.state = state; self.createdAt = createdAt; self.lastReviewedAt = lastReviewedAt
        self.history = history.isEmpty ? [ReviewEvent(action: .added, at: createdAt)] : history
    }
}

// MARK: - Pages, revisions, documents

public struct Page: Hashable, Codable, Sendable, Identifiable {
    public var id: PageID
    /// Visible page size in page points (after any PDF rotation).
    public var size: PageSize
    public var background: PageBackground
    /// Back-to-front order within the object band.
    public var objects: [CanvasObject]
    public var inkLayers: [InkLayer]
    public var problem: ProblemMetadata?
    public var isBookmarked: Bool
    /// Revision that last changed this page's content file.
    public var revisionID: RevisionID
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: PageID = PageID(), size: PageSize, background: PageBackground, objects: [CanvasObject] = [],
                inkLayers: [InkLayer] = [InkLayer()], problem: ProblemMetadata? = nil, isBookmarked: Bool = false,
                revisionID: RevisionID, createdAt: Date, modifiedAt: Date) {
        self.id = id; self.size = size; self.background = background; self.objects = objects
        self.inkLayers = inkLayers; self.problem = problem; self.isBookmarked = isBookmarked
        self.revisionID = revisionID; self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
    public var bounds: PageRect { PageRect(origin: .zero, size: size) }
    public var isProblemPage: Bool { problem != nil }
    /// Every asset this page references (background, images, ink blobs).
    public var referencedAssetIDs: Set<AssetID> {
        var ids = Set<AssetID>()
        if let a = background.assetID { ids.insert(a) }
        for o in objects { if let a = o.content.assetID { ids.insert(a) } }
        for l in inkLayers { if let a = l.dataAssetID { ids.insert(a) } }
        return ids
    }
    public func object(_ id: ObjectID) -> CanvasObject? { objects.first { $0.id == id } }
    public func objectIndex(_ id: ObjectID) -> Int? { objects.firstIndex { $0.id == id } }
}

public struct Revision: Hashable, Codable, Sendable, Identifiable {
    public var id: RevisionID
    public var parentIDs: [RevisionID]
    /// Monotonic per document; the head has the largest sequence.
    public var sequence: Int
    public var createdAt: Date
    public var changedPageIDs: [PageID]
    public var schemaVersion: Int
    public var summary: String?
    public init(id: RevisionID = RevisionID(), parentIDs: [RevisionID], sequence: Int, createdAt: Date,
                changedPageIDs: [PageID], schemaVersion: Int = DocumentSchema.current, summary: String? = nil) {
        self.id = id; self.parentIDs = parentIDs; self.sequence = sequence; self.createdAt = createdAt
        self.changedPageIDs = changedPageIDs; self.schemaVersion = schemaVersion; self.summary = summary
    }
}

/// A deleted page retained for restore. Kept in the document until the
/// student empties it or the retention window (Persistence policy) expires.
public struct DeletedPage: Hashable, Codable, Sendable, Identifiable {
    public var page: Page
    public var originalIndex: Int
    public var deletedAt: Date
    public var id: PageID { page.id }
    public init(page: Page, originalIndex: Int, deletedAt: Date) {
        self.page = page; self.originalIndex = originalIndex; self.deletedAt = deletedAt
    }
}

/// Document-level metadata as stored in the package manifest. Page content is
/// stored per page (see `DocumentSnapshot`); this struct only orders pages.
public struct Document: Hashable, Codable, Sendable, Identifiable {
    public var id: DocumentID
    public var schemaVersion: Int
    public var kind: DocumentKind
    public var title: String
    public var folderID: FolderID?
    public var language: String
    public var cover: CoverStyle
    public var defaultTemplate: PaperTemplate
    public var defaultPageSize: PageSize
    public var isFavorite: Bool
    public var pageIDs: [PageID]
    public var deletedPages: [DeletedPage]
    public var reviewItems: [ReviewItem]
    public var revisionHead: RevisionID
    public var createdAt: Date
    public var modifiedAt: Date
    public var lastOpenedAt: Date?
    /// Index of the page the editor last showed, restored on reopen.
    public var lastViewedPageIndex: Int

    public init(id: DocumentID = DocumentID(), schemaVersion: Int = DocumentSchema.current, kind: DocumentKind = .notebook,
                title: String, folderID: FolderID? = nil, language: String = "en", cover: CoverStyle = .default,
                defaultTemplate: PaperTemplate = .lined, defaultPageSize: PageSize = .letter, isFavorite: Bool = false,
                pageIDs: [PageID], deletedPages: [DeletedPage] = [], reviewItems: [ReviewItem] = [],
                revisionHead: RevisionID, createdAt: Date, modifiedAt: Date, lastOpenedAt: Date? = nil, lastViewedPageIndex: Int = 0) {
        self.id = id; self.schemaVersion = schemaVersion; self.kind = kind; self.title = title; self.folderID = folderID
        self.language = language; self.cover = cover; self.defaultTemplate = defaultTemplate; self.defaultPageSize = defaultPageSize
        self.isFavorite = isFavorite; self.pageIDs = pageIDs; self.deletedPages = deletedPages; self.reviewItems = reviewItems
        self.revisionHead = revisionHead; self.createdAt = createdAt; self.modifiedAt = modifiedAt
        self.lastOpenedAt = lastOpenedAt; self.lastViewedPageIndex = lastViewedPageIndex
    }
    public var pageCount: Int { pageIDs.count }
}

// MARK: - Library

public struct Folder: Hashable, Codable, Sendable, Identifiable {
    public var id: FolderID
    public var name: String
    public var parentID: FolderID?
    /// A course folder owns a review queue; nested folders inside it contribute to the queue.
    public var isCourse: Bool
    public var color: CoverStyle.Palette
    public var isFavorite: Bool
    public var createdAt: Date
    public var sortIndex: Int
    public init(id: FolderID = FolderID(), name: String, parentID: FolderID? = nil, isCourse: Bool = false,
                color: CoverStyle.Palette = .slate, isFavorite: Bool = false, createdAt: Date, sortIndex: Int = 0) {
        self.id = id; self.name = name; self.parentID = parentID; self.isCourse = isCourse; self.color = color
        self.isFavorite = isFavorite; self.createdAt = createdAt; self.sortIndex = sortIndex
    }
}

/// Library-level manifest (`library.json`): the folder tree and recoverable
/// trash entries. Documents record their own folder membership; the catalog
/// (SQLite) is a rebuildable index over this manifest and the packages.
public struct LibraryManifest: Hashable, Codable, Sendable {
    public var schemaVersion: Int
    public var folders: [Folder]
    public var trash: [TrashEntry]
    public var modifiedAt: Date
    public init(schemaVersion: Int = DocumentSchema.current, folders: [Folder] = [], trash: [TrashEntry] = [], modifiedAt: Date) {
        self.schemaVersion = schemaVersion; self.folders = folders; self.trash = trash; self.modifiedAt = modifiedAt
    }
    public func folder(_ id: FolderID) -> Folder? { folders.first { $0.id == id } }
    /// The nearest enclosing course folder (including `id` itself), if any.
    public func courseFolder(containing id: FolderID?) -> Folder? {
        var current = id.flatMap(folder)
        var guardCount = 0
        while let f = current, guardCount < 1000 {
            if f.isCourse { return f }
            current = f.parentID.flatMap(folder); guardCount += 1
        }
        return nil
    }
    /// All folder IDs in the subtree rooted at `id` (inclusive).
    public func subtree(of id: FolderID) -> Set<FolderID> {
        var result: Set<FolderID> = [id]
        var frontier = [id]
        while let next = frontier.popLast() {
            for f in folders where f.parentID == next && !result.contains(f.id) { result.insert(f.id); frontier.append(f.id) }
        }
        return result
    }
}

public struct TrashEntry: Hashable, Codable, Sendable, Identifiable {
    public enum Item: Hashable, Codable, Sendable {
        case document(DocumentID)
        case folder(Folder, documentIDs: [DocumentID])
    }
    public var id: UUID
    public var item: Item
    public var title: String
    public var originalFolderID: FolderID?
    public var deletedAt: Date
    public init(id: UUID = UUID(), item: Item, title: String, originalFolderID: FolderID?, deletedAt: Date) {
        self.id = id; self.item = item; self.title = title; self.originalFolderID = originalFolderID; self.deletedAt = deletedAt
    }
}
