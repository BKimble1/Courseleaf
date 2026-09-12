import Foundation
import DocumentCore
import Workspace

/// Where an exporter or recognizer reads a document and its asset bytes from.
/// `SessionContentSource` adapts an open `DocumentSessioning`; the in-memory
/// variant lets tests drive the real renderers without a library on disk.
protocol ExportContentSource: Sendable {
    func snapshot() async -> DocumentSnapshot
    /// Bytes of a committed or pending asset; nil when unknown.
    func assetData(_ id: AssetID) async throws -> Data?
    /// File URL of a committed asset (lets PDFKit/ImageIO map the file); nil for pending assets.
    func assetURL(_ id: AssetID) async -> URL?
}

/// Reads through an open document session. The session is main-actor bound;
/// every access hops there and returns plain values, so rendering itself can
/// run on a background task.
struct SessionContentSource: ExportContentSource, @unchecked Sendable {
    let session: any DocumentSessioning
    init(session: any DocumentSessioning) { self.session = session }

    func snapshot() async -> DocumentSnapshot { await MainActor.run { session.editor.snapshot } }
    func assetData(_ id: AssetID) async throws -> Data? { try await session.assetData(id) }
    func assetURL(_ id: AssetID) async -> URL? { await session.assetURL(id) }
}

/// A snapshot plus asset bytes held in memory (tests, previews).
struct InMemoryContentSource: ExportContentSource {
    let documentSnapshot: DocumentSnapshot
    let assets: [AssetID: Data]
    init(snapshot: DocumentSnapshot, assets: [AssetID: Data]) {
        self.documentSnapshot = snapshot
        self.assets = assets
    }
    func snapshot() async -> DocumentSnapshot { documentSnapshot }
    func assetData(_ id: AssetID) async throws -> Data? { assets[id] }
    func assetURL(_ id: AssetID) async -> URL? { nil }
}

enum ExportError: Error, LocalizedError, Equatable {
    case pageNotFound(PageID)
    case noPagesSelected
    case missingAsset(AssetID, pageID: PageID)
    case unreadableAsset(AssetID, reason: String)
    case sourcePageMissing(AssetID, pageIndex: Int)
    case renderFailed(String)
    case writeFailed(String)
    case unsupportedFormat(ExportFormat)

    var errorDescription: String? {
        switch self {
        case .pageNotFound(let id): return "Page \(id) is not in the document."
        case .noPagesSelected: return "No pages were selected for export."
        case .missingAsset(let id, let page): return "Page \(page) refers to missing content (\(id))."
        case .unreadableAsset(let id, let reason): return "Content \(id) could not be read: \(reason)"
        case .sourcePageMissing(let id, let index): return "Page \(index + 1) of the source PDF \(id) could not be opened."
        case .renderFailed(let reason): return "Rendering failed: \(reason)"
        case .writeFailed(let reason): return "The export could not be written: \(reason)"
        case .unsupportedFormat(let format): return "\(format.rawValue.uppercased()) is not produced by this exporter."
        }
    }
}
