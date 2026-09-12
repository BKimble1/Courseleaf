import XCTest
import CoreGraphics
import UIKit
import PencilKit
import DocumentCore
import Fixtures
@testable import Courseleaf

// Shared helpers for the Interchange simulator tests: temporary directories,
// in-memory documents, and pixel sampling of rendered output. Everything
// asserted is externally observable (bytes on disk, pixels, coordinates).

enum InterchangeTestSupport {
    static let fixedDate = Date(timeIntervalSince1970: 1_757_600_000)

    /// A fresh directory under the system temporary directory; remove it in `tearDown`.
    static func makeTemporaryDirectory(_ name: String = "InterchangeTests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A document holding exactly `pages` (in order) and `assets`, plus the asset bytes for an in-memory source.
    static func makeDocument(title: String = "Interchange", pages: [Page], assets: [PendingAsset]) -> (DocumentSnapshot, InMemoryContentSource) {
        let revision = Revision(parentIDs: [], sequence: 1, createdAt: fixedDate, changedPageIDs: pages.map(\.id))
        let document = Document(title: title, pageIDs: pages.map(\.id), revisionHead: revision.id, createdAt: fixedDate, modifiedAt: fixedDate)
        var pageMap: [PageID: Page] = [:]
        var pagesWithRevision: [Page] = []
        for var page in pages {
            page.revisionID = revision.id
            pageMap[page.id] = page
            pagesWithRevision.append(page)
        }
        var assetMap: [AssetID: SourceAsset] = [:]
        var bytes: [AssetID: Data] = [:]
        for pending in assets {
            assetMap[pending.asset.id] = pending.asset
            bytes[pending.asset.id] = pending.data
        }
        let snapshot = DocumentSnapshot(document: document, pages: pageMap, assets: assetMap, revisions: [revision.id: revision])
        return (snapshot, InMemoryContentSource(snapshot: snapshot, assets: bytes))
    }

    static func page(size: PageSize, background: PageBackground, objects: [CanvasObject] = [], inkLayers: [InkLayer] = [InkLayer()]) -> Page {
        Page(size: size, background: background, objects: objects, inkLayers: inkLayers,
             revisionID: RevisionID(), createdAt: fixedDate, modifiedAt: fixedDate)
    }

    /// A filled black square shape object at `rect` (no stroke, so its edges are exactly `rect`).
    static func blackSquare(at rect: PageRect) -> CanvasObject {
        CanvasObject(frame: rect, content: .shape(ShapeContent(kind: .rectangle, strokeColor: .black, strokeWidth: 0, fillColor: .black)),
                     createdAt: fixedDate)
    }

    /// A PencilKit drawing with one horizontal pen stroke of `width` points from (x0, y) to (x1, y).
    static func horizontalPenStroke(y: Double, from x0: Double, to x1: Double, width: Double = 10) -> PKDrawing {
        var points: [PKStrokePoint] = []
        var x = x0
        while x <= x1 {
            points.append(PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: (x - x0) / 100, size: CGSize(width: width, height: width),
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
            x += 5
        }
        let path = PKStrokePath(controlPoints: points, creationDate: fixedDate)
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
    }
}

/// RGBA8 pixels of a rendered page with helpers that address *page points*.
struct PixelSampler {
    let width: Int
    let height: Int
    let scale: CGFloat
    private let bytes: [UInt8]

    init(cgImage: CGImage, scale: CGFloat) {
        // Local copies: the closure below must not capture `self` while `bytes`
        // is still uninitialized.
        let w = cgImage.width, h = cgImage.height
        width = w
        height = h
        self.scale = scale
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        bytes = data
    }

    init(image: UIImage) {
        self.init(cgImage: image.cgImage!, scale: image.scale)
    }

    /// Rasterizes page `index` of the PDF at `url` with CoreGraphics (media box at the origin, y down).
    static func rasterizePDF(at url: URL, pageIndex: Int, scale: CGFloat = 2) throws -> PixelSampler {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: pageIndex + 1) else {
            throw XCTSkip("could not open exported PDF page \(pageIndex)")
        }
        let box = page.getBoxRect(.mediaBox)
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        var data = [UInt8](repeating: 255, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
        }
        return PixelSampler(width: width, height: height, scale: scale, bytes: data)
    }

    private init(width: Int, height: Int, scale: CGFloat, bytes: [UInt8]) {
        self.width = width; self.height = height; self.scale = scale; self.bytes = bytes
    }

    /// Channel value 0...1 at a page point (row 0 is the top of the page).
    func channel(_ channel: Int, x: Double, y: Double) -> Double {
        let px = min(max(Int((CGFloat(x) * scale).rounded(.down)), 0), width - 1)
        let py = min(max(Int((CGFloat(y) * scale).rounded(.down)), 0), height - 1)
        return Double(bytes[(py * width + px) * 4 + channel]) / 255
    }

    /// Relative luminance 0 (black) ... 1 (white) at a page point.
    func luminance(x: Double, y: Double) -> Double {
        0.2126 * channel(0, x: x, y: y) + 0.7152 * channel(1, x: x, y: y) + 0.0722 * channel(2, x: x, y: y)
    }

    /// Darkest luminance in a (2r+1)² pixel neighbourhood around a page point.
    func minimumLuminance(x: Double, y: Double, radiusPixels r: Int = 1) -> Double {
        var best = 1.0
        for dy in -r...r {
            for dx in -r...r {
                best = min(best, luminance(x: x + Double(dx) / Double(scale), y: y + Double(dy) / Double(scale)))
            }
        }
        return best
    }
}
