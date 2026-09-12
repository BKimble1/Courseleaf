import Foundation
import UIKit
import PDFKit
import DocumentCore
import PageGeometry

/// Tiled background of a page: procedural paper template, the source PDF page
/// positioned through `PageMapping.pdfUserToPage`, or a full-page image.
/// CATiledLayer renders tiles on background threads, so the content is
/// guarded by a lock and never mutated in place.
final class PageBackgroundLayerView: UIView {
    override class var layerClass: AnyClass { PageTiledLayer.self }

    private let lock = NSLock()
    private var storedContent: PageBackgroundContent = .empty(paperColor: .white)

    var content: PageBackgroundContent {
        get { lock.lock(); defer { lock.unlock() }; return storedContent }
        set {
            lock.lock(); storedContent = newValue; lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.layer.setNeedsDisplay() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .white
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        let scale = UIScreen.main.scale
        if let tiled = layer as? CATiledLayer {
            tiled.tileSize = CGSize(width: 512 * scale, height: 512 * scale)
            tiled.levelsOfDetail = 5
            tiled.levelsOfDetailBias = 4   // sharp up to ~16x of the layer's own scale (zoom 8 with Retina)
            tiled.contentsScale = scale
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let content = self.content
        PageRenderer.drawBackground(content, pageSize: bounds.size, in: ctx, rect: rect)
    }
}

final class PageTiledLayer: CATiledLayer {
    /// Tiles appear immediately instead of fading in, which looks better while scrolling handwriting.
    override class func fadeDuration() -> CFTimeInterval { 0 }
}
