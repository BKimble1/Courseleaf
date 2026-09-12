import Foundation
import UIKit
import DocumentCore
import Editing
import Workspace

/// Turns scanned or picked `UIImage`s into JPEG assets and either full-page
/// image pages (scans) or image objects on an existing page (photos), through
/// the session's public API (`addAsset` + `EditCommand`s). The image page's
/// width is US Letter (612 pt, the same rule Workspace's file import uses) and
/// its height follows the image aspect ratio, so the scan fills the page.
struct ImageImportBuilder {
    var jpegQuality: CGFloat = 0.85
    /// Page width for full-page image pages, in points.
    var pageWidth: Double = PageSize.letter.width
    /// Longest side of a scan in pixels; larger images are downscaled before encoding.
    var maximumPixelDimension: CGFloat = 4096

    init() {}

    struct Built {
        var pages: [Page]
        var assets: [PendingAsset]
    }

    /// Full-page image pages and their assets (not yet applied to any document).
    func makePages(from images: [UIImage], revisionID: RevisionID, now: Date, namePrefix: String = "scan") -> Built {
        var pages: [Page] = []
        var assets: [PendingAsset] = []
        for (index, image) in images.enumerated() {
            guard let (data, pixelSize) = encode(image) else { continue }
            let asset = PendingAsset.make(data: data, mediaType: .jpeg, originalFileName: "\(namePrefix)-\(index + 1).jpg", now: now)
            let height = (pageWidth * Double(pixelSize.height) / Double(pixelSize.width) * 1000).rounded() / 1000
            let page = Page(size: PageSize(width: pageWidth, height: height), background: .image(asset.asset.id),
                            revisionID: revisionID, createdAt: now, modifiedAt: now)
            assets.append(asset)
            pages.append(page)
        }
        return Built(pages: pages, assets: assets)
    }

    /// Inserts one page per image after `afterPageIndex` (nil = at the end) as one undo step.
    @MainActor
    @discardableResult
    func insertPages(from images: [UIImage], into session: any DocumentSessioning, afterPageIndex: Int?, now: Date = Date()) throws -> [PageID] {
        let document = session.editor.document
        let built = makePages(from: images, revisionID: document.revisionHead, now: now)
        guard !built.pages.isEmpty else { return [] }
        let count = document.pageIDs.count
        let index = afterPageIndex.map { min(max($0 + 1, 0), count) } ?? count
        for asset in built.assets { session.addAsset(asset) }
        try session.performGrouped("Insert Scans") {
            try session.apply(.insertPages(built.pages, at: index))
        }
        return built.pages.map(\.id)
    }

    /// Adds a photo as an image object centred on `pageID`, fitted into 60 % of the page.
    @MainActor
    @discardableResult
    func insertImageObject(_ image: UIImage, onto pageID: PageID, in session: any DocumentSessioning, now: Date = Date()) throws -> ObjectID? {
        guard let page = session.editor.page(pageID) else { throw EditingError.pageNotFound(pageID) }
        guard let (data, pixelSize) = encode(image) else { return nil }
        let asset = PendingAsset.make(data: data, mediaType: .jpeg, originalFileName: "photo.jpg", now: now)
        let maxWidth = page.size.width * 0.6, maxHeight = page.size.height * 0.6
        let scale = min(maxWidth / Double(pixelSize.width), maxHeight / Double(pixelSize.height), 1)
        let width = Double(pixelSize.width) * scale, height = Double(pixelSize.height) * scale
        let frame = PageRect(x: (page.size.width - width) / 2, y: (page.size.height - height) / 2, width: width, height: height)
        let object = CanvasObject(frame: frame, content: .image(ImageContent(assetID: asset.asset.id)), createdAt: now)
        session.addAsset(asset)
        try session.performGrouped("Insert Photo") {
            try session.apply(.addObject(pageID, object, at: nil))
        }
        return object.id
    }

    /// Upright JPEG bytes and the encoded pixel size (after any downscale).
    func encode(_ image: UIImage) -> (Data, CGSize)? {
        var upright = image.ixNormalizedOrientation()
        let longest = max(upright.size.width * upright.scale, upright.size.height * upright.scale)
        if longest > maximumPixelDimension, longest > 0 {
            let factor = maximumPixelDimension / longest
            let target = CGSize(width: (upright.size.width * upright.scale * factor).rounded(.down),
                                height: (upright.size.height * upright.scale * factor).rounded(.down))
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            upright = UIGraphicsImageRenderer(size: target, format: format).image { _ in upright.draw(in: CGRect(origin: .zero, size: target)) }
        }
        guard let cg = upright.cgImage, cg.width > 0, cg.height > 0 else { return nil }
        guard let data = upright.jpegData(compressionQuality: jpegQuality) else { return nil }
        return (data, CGSize(width: cg.width, height: cg.height))
    }
}
