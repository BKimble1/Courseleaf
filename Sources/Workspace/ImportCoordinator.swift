import Foundation
import DocumentCore
import Archive

/// Turns import requests into pages and pending assets without touching the
/// library. PDFs are inspected through the injected `PDFInspecting` (one
/// page per PDF page, page space = the rotated CropBox); images through
/// `ImageInspecting` (one full-page image page at Letter width); archives are
/// validated with `ArchiveReader` and yield re-identified snapshots. The
/// library service commits the prepared material at the end so a failed
/// import never leaves anything behind.
public struct ImportCoordinator: Sendable {
    /// Pages and assets prepared from one or more requests.
    public struct Prepared: Sendable {
        public var pages: [Page] = []
        public var assets: [PendingAsset] = []
        public var warnings: [String] = []
        /// Title suggestion for a new notebook (the first source file's name without its extension).
        public var suggestedTitle: String?
        public init() {}
    }

    /// A document restored from an archive, re-identified as a copy unless asked otherwise.
    public struct ArchivedDocument: Sendable {
        public var snapshot: DocumentSnapshot
        public var assets: [PendingAsset]
        public var originalID: DocumentID
    }

    /// Page width used for image pages; the height keeps the image's aspect ratio.
    public static let imagePageWidth: Double = PageSize.letter.width

    public let pdfInspector: any PDFInspecting
    public let imageInspector: any ImageInspecting
    public let clock: any Clock

    public init(pdfInspector: any PDFInspecting, imageInspector: any ImageInspecting, clock: any Clock) {
        self.pdfInspector = pdfInspector; self.imageInspector = imageInspector; self.clock = clock
    }

    // MARK: Kind detection

    /// Resolves `.auto` from the file extension, falling back to sniffing the bytes.
    public func resolvedKind(of request: ImportRequest, data: Data) -> ImportKind {
        guard request.kind == .auto else { return request.kind }
        switch request.sourceURL.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "png", "jpg", "jpeg": return .image
        case "courseleaf", "zip": return .archive
        default: break
        }
        if data.starts(with: Array("%PDF-".utf8)) { return .pdf }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .archive }
        if (try? imageInspector.inspect(data: data)) != nil { return .image }
        return .auto
    }

    // MARK: Staging

    /// Copies the source file into `stagingDirectory` (security-scoped access
    /// is the app's concern; on Linux and in tests the URL is a plain file).
    public func stage(_ request: ImportRequest, in stagingDirectory: URL) throws -> URL {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: request.sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw WorkspaceError.importFailed("\(request.sourceURL.lastPathComponent) does not exist")
        }
        let name = request.sourceURL.lastPathComponent.isEmpty ? "import" : request.sourceURL.lastPathComponent
        let destination = stagingDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        do { try fm.copyItem(at: request.sourceURL, to: destination) }
        catch { throw WorkspaceError.importFailed("could not copy \(name) into staging: \(error.localizedDescription)") }
        return destination
    }

    // MARK: PDF and image pages

    /// Pages for one PDF or image file already copied to `stagedURL`.
    /// `existingDigests` maps asset digests already in the library/document to a description for duplicate warnings.
    public func preparePages(request: ImportRequest, stagedURL: URL, revisionID: RevisionID,
                             existingDigests: [String: String] = [:]) throws -> Prepared {
        let data: Data
        do { data = try Data(contentsOf: stagedURL) } catch { throw WorkspaceError.importFailed("could not read \(request.sourceURL.lastPathComponent)") }
        let kind = resolvedKind(of: request, data: data)
        let name = request.sourceURL.lastPathComponent
        var prepared = Prepared()
        prepared.suggestedTitle = request.sourceURL.deletingPathExtension().lastPathComponent
        let now = clock.now()
        switch kind {
        case .pdf:
            let info: PDFFileInfo
            do { info = try pdfInspector.inspect(fileAt: stagedURL) }
            catch let error as PDFInspectionError { throw Self.translate(error, fileName: name) }
            catch { throw WorkspaceError.importFailed("\(name): \(error)") }
            if info.isEncrypted { throw WorkspaceError.unsupportedFile("\(name) is encrypted; remove the password before importing") }
            guard info.pageCount > 0, info.pages.count == info.pageCount else { throw WorkspaceError.importFailed("\(name) has no pages") }
            let asset = PendingAsset.make(data: data, mediaType: .pdf, originalFileName: name, pageCount: info.pageCount, now: now)
            if let existing = existingDigests[asset.asset.sha256] { prepared.warnings.append("\(name) was already imported (\(existing))") }
            prepared.assets.append(asset)
            for page in info.pages {
                let source = page.source(assetID: asset.asset.id)
                let size = source.displaySize
                guard size.isValid else { throw WorkspaceError.importFailed("\(name): page \(page.index + 1) has an empty crop box") }
                prepared.pages.append(Page(size: size, background: .pdf(source), revisionID: revisionID, createdAt: now, modifiedAt: now))
            }
            if !info.outlineTitles.isEmpty {
                prepared.warnings.append("Outline of \(name): " + info.outlineTitles.joined(separator: "; "))
            }
        case .image:
            let info: ImageInfo
            do { info = try imageInspector.inspect(data: data) }
            catch ImageInspectionError.unsupported { throw WorkspaceError.unsupportedFile("\(name) is not a PNG or JPEG image") }
            catch { throw WorkspaceError.importFailed("\(name) is not a readable image") }
            guard info.pixelWidth > 0, info.pixelHeight > 0 else { throw WorkspaceError.importFailed("\(name) has no pixels") }
            let asset = PendingAsset.make(data: data, mediaType: info.mediaType, originalFileName: name, now: now)
            if let existing = existingDigests[asset.asset.sha256] { prepared.warnings.append("\(name) was already imported (\(existing))") }
            prepared.assets.append(asset)
            let width = Self.imagePageWidth
            let height = (width * Double(info.pixelHeight) / Double(info.pixelWidth) * 1000).rounded() / 1000
            prepared.pages.append(Page(size: PageSize(width: width, height: height), background: .image(asset.asset.id),
                                       revisionID: revisionID, createdAt: now, modifiedAt: now))
        case .archive:
            throw WorkspaceError.importFailed("\(name) is an archive; use prepareArchive")
        case .auto:
            throw WorkspaceError.unsupportedFile("\(name) is not a PDF, image or Courseleaf archive")
        }
        return prepared
    }

    // MARK: Archives

    /// Validates the archive and returns every document in it, re-identified
    /// as a copy (`asCopies`) or with its original identifiers.
    public func prepareArchive(stagedURL: URL, asCopies: Bool) throws -> (documents: [ArchivedDocument], library: LibraryManifest?) {
        let reader: ArchiveReader
        do { reader = try ArchiveReader.open(url: stagedURL) }
        catch let error as ArchiveError { throw WorkspaceError.archive(error.description) }
        catch { throw WorkspaceError.archive("\(error)") }
        var documents: [ArchivedDocument] = []
        for id in reader.inventory.documentIDs {
            let (snapshot, provider) = try reader.document(id)
            var assets: [PendingAsset] = []
            for assetID in snapshot.assets.keys.sorted() {
                let asset = snapshot.assets[assetID]!
                do { assets.append(PendingAsset(asset: asset, data: try provider(asset))) }
                catch let error as ArchiveError { throw WorkspaceError.archive(error.description) }
            }
            let restored = asCopies ? snapshot.reidentifiedCopy() : snapshot
            documents.append(ArchivedDocument(snapshot: restored, assets: assets, originalID: id))
        }
        return (documents, reader.library())
    }

    /// Copies of the archived documents' live pages (fresh page, object and
    /// ink-layer ids) for insertion into another notebook, plus their assets.
    public func pages(fromArchived documents: [ArchivedDocument], revisionID: RevisionID) -> Prepared {
        var prepared = Prepared()
        let now = clock.now()
        var seenAssets = Set<AssetID>()
        for document in documents {
            for asset in document.assets where seenAssets.insert(asset.asset.id).inserted { prepared.assets.append(asset) }
            for page in document.snapshot.orderedPages {
                var copy = page
                copy.id = PageID()
                copy.objects = page.objects.map { var o = $0; o.id = ObjectID(); return o }
                copy.inkLayers = page.inkLayers.map { var l = $0; l.id = InkLayerID(); return l }
                copy.revisionID = revisionID
                copy.createdAt = now; copy.modifiedAt = now
                prepared.pages.append(copy)
            }
            if !document.snapshot.document.reviewItems.isEmpty {
                prepared.warnings.append("Review items of '\(document.snapshot.document.title)' were not inserted; restore the archive as a notebook to keep them")
            }
        }
        return prepared
    }

    static func translate(_ error: PDFInspectionError, fileName: String) -> WorkspaceError {
        switch error {
        case .notAPDF: return .unsupportedFile("\(fileName) is not a PDF")
        case .encrypted: return .unsupportedFile("\(fileName) is encrypted; remove the password before importing")
        case .corrupt(let reason): return .importFailed("\(fileName) is damaged: \(reason)")
        case .tooLarge(let bytes, let limit): return .importFailed("\(fileName) is too large (\(bytes) bytes, limit \(limit))")
        case .cancelled: return .cancelled
        }
    }
}

extension DocumentSnapshot {
    /// A copy under a fresh document identity (Archive's re-identifier, so
    /// archive restores and duplicates share one implementation).
    func reidentifiedCopy() -> DocumentSnapshot { SnapshotReidentifier.copy(self) }
}
