import Foundation
import DocumentCore

/// Maps between a source page's PDF user space and Courseleaf *page space*.
///
/// Page space (docs/ARCHITECTURE.md §3) is the visible page — the CropBox
/// intersected with the MediaBox — after the page's `/Rotate` has been
/// applied, with the origin at the top-left corner, x to the right and y
/// downward, in PDF points.
///
/// ## Derivation
///
/// Let the effective crop box in PDF user space (origin bottom-left, y up) be
/// `[cx0 cy0 cx1 cy1]` with `cw = cx1 - cx0` and `ch = cy1 - cy0`.
///
/// Step 1 — un-rotated page space. Translate the crop origin to (0, 0) and
/// flip y so it points down:
///
///     u = x - cx0
///     v = cy1 - y
///
/// `(u, v)` is page space for `/Rotate 0`; its size is `cw × ch`.
///
/// Step 2 — `/Rotate`. The PDF specification defines `/Rotate` as the number
/// of degrees the page is rotated **clockwise when displayed**. Rotating the
/// un-rotated image clockwise by 90° moves its top-left corner to the top-right
/// of the displayed page and its bottom-left corner to the displayed top-left.
/// The displayed size swaps to `ch × cw`. Writing the displayed coordinates as
/// `(X, Y)`:
///
///     /Rotate 0    X = u           Y = v           size cw × ch
///     /Rotate 90   X = ch - v      Y = u           size ch × cw
///     /Rotate 180  X = cw - u      Y = ch - v      size cw × ch
///     /Rotate 270  X = v           Y = cw - u      size ch × cw
///
/// (Check for 90: `(u,v) = (0,0)` → `(ch, 0)` top-right; `(0, ch)` → `(0, 0)`
/// top-left; `(cw, 0)` → `(ch, cw)` bottom-right. For 270 the rotation is
/// counter-clockwise on screen: `(0,0)` → `(0, cw)` bottom-left; `(cw, 0)` →
/// `(0, 0)` top-left.)
///
/// Substituting step 1 gives `pdfUserToPage` directly in user coordinates:
///
///     /Rotate 0    X = x - cx0     Y = cy1 - y
///     /Rotate 90   X = y - cy0     Y = x - cx0
///     /Rotate 180  X = cx1 - x     Y = y - cy0
///     /Rotate 270  X = cy1 - y     Y = cx1 - x
///
/// expressed as `PageTransform` (`x' = a·x + c·y + tx`, `y' = b·x + d·y + ty`):
///
///     0:    a= 1 b= 0 c= 0 d=-1  tx=-cx0  ty= cy1
///     90:   a= 0 b= 1 c= 1 d= 0  tx=-cy0  ty=-cx0
///     180:  a=-1 b= 0 c= 0 d= 1  tx= cx1  ty=-cy0
///     270:  a= 0 b=-1 c=-1 d= 0  tx= cy1  ty= cx1
///
/// `pageToPDFUser` is the exact inverse. Template pages have no PDF user
/// space of their own; for export they are treated as an un-rotated page
/// whose MediaBox and CropBox are `[0 0 width height]`, so `pdfUserToPage`
/// is a plain y-flip.
public struct PageMapping: Hashable, Sendable {
    /// Effective crop box in PDF user space (already intersected with the MediaBox).
    public let cropBox: PageRect
    public let rotation: PageRotation
    /// Visible page size in page points (after rotation): the page-space extent.
    public let pageSize: PageSize
    /// PDF user space → page space.
    public let pdfUserToPage: PageTransform
    /// Page space → PDF user space (inverse of `pdfUserToPage`).
    public let pageToPDFUser: PageTransform

    /// Mapping for an imported PDF page. The crop box is intersected with the
    /// media box; if they do not overlap the media box is used.
    public init(source: PDFPageSource) {
        self.init(mediaBox: source.mediaBox, cropBox: source.cropBox, rotation: source.rotation)
    }

    /// Mapping for a template (or full-page image) page: no crop, no rotation.
    public init(templateSize: PageSize) {
        let box = PageRect(origin: .zero, size: templateSize)
        self.init(mediaBox: box, cropBox: box, rotation: .degrees0)
    }

    public init(mediaBox: PageRect, cropBox: PageRect?, rotation: PageRotation) {
        let media = mediaBox.standardized
        let crop = (cropBox?.standardized).flatMap { media.intersection($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? media
        self.cropBox = crop
        self.rotation = rotation
        let cx0 = crop.minX, cy0 = crop.minY, cx1 = crop.maxX, cy1 = crop.maxY
        let unrotated = PageSize(width: crop.width, height: crop.height)
        pageSize = rotation.swapsWidthAndHeight ? unrotated.swapped : unrotated
        let forward: PageTransform
        switch rotation {
        case .degrees0:   forward = PageTransform(a: 1, b: 0, c: 0, d: -1, tx: -cx0, ty: cy1)
        case .degrees90:  forward = PageTransform(a: 0, b: 1, c: 1, d: 0, tx: -cy0, ty: -cx0)
        case .degrees180: forward = PageTransform(a: -1, b: 0, c: 0, d: 1, tx: cx1, ty: -cy0)
        case .degrees270: forward = PageTransform(a: 0, b: -1, c: -1, d: 0, tx: cy1, ty: cx1)
        }
        pdfUserToPage = forward
        // Every case above is orthonormal (determinant ±1), so the inverse always exists.
        pageToPDFUser = forward.inverted() ?? .identity
    }

    /// The page-space bounds: origin zero, size `pageSize`.
    public var pageBounds: PageRect { PageRect(origin: .zero, size: pageSize) }

    public func pageRect(fromPDFUser rect: PageRect) -> PageRect { rect.applying(pdfUserToPage) }
    public func pdfUserRect(fromPage rect: PageRect) -> PageRect { rect.applying(pageToPDFUser) }
    public func pagePoint(fromPDFUser point: PagePoint) -> PagePoint { pdfUserToPage.apply(point) }
    public func pdfUserPoint(fromPage point: PagePoint) -> PagePoint { pageToPDFUser.apply(point) }

    /// Page space → canvas/screen coordinates for the given zoom and scroll offset (see `CanvasMapping`).
    public func pageToCanvas(scale: Double, offset: PagePoint) -> PageTransform {
        CanvasMapping(zoomScale: scale, contentOffset: offset).pageToCanvas
    }
    /// Canvas/screen coordinates → page space.
    public func canvasToPage(scale: Double, offset: PagePoint) -> PageTransform {
        CanvasMapping(zoomScale: scale, contentOffset: offset).canvasToPage
    }
}

/// Page space ↔ canvas (screen) coordinates.
///
/// The canvas for a page is laid out so that one canvas point equals one page
/// point at zoom 1 with the canvas origin at the page origin; the containing
/// scroll view applies the zoom. In the scroll view's content space the page
/// therefore occupies `pageOrigin + page × zoomScale`, and the visible
/// (scroll view bounds) coordinate is that minus `contentOffset`:
///
///     canvas = (page × zoomScale) + pageOrigin − contentOffset
///
/// `pageOrigin` is the page's origin inside the zoomed content (zero for a
/// single-page layout; the page's top-left for continuous scrolling).
public struct CanvasMapping: Hashable, Sendable {
    public var zoomScale: Double
    public var contentOffset: PagePoint
    public var pageOrigin: PagePoint

    public init(zoomScale: Double, contentOffset: PagePoint = .zero, pageOrigin: PagePoint = .zero) {
        precondition(zoomScale.isFinite && zoomScale > 0, "zoomScale must be positive and finite")
        self.zoomScale = zoomScale; self.contentOffset = contentOffset; self.pageOrigin = pageOrigin
    }

    public var pageToCanvas: PageTransform {
        PageTransform.scale(zoomScale)
            .concatenating(.translation(x: pageOrigin.x - contentOffset.x, y: pageOrigin.y - contentOffset.y))
    }
    public var canvasToPage: PageTransform { pageToCanvas.inverted() ?? .identity }

    public func canvasPoint(fromPage p: PagePoint) -> PagePoint { pageToCanvas.apply(p) }
    public func pagePoint(fromCanvas p: PagePoint) -> PagePoint { canvasToPage.apply(p) }
    public func canvasRect(fromPage r: PageRect) -> PageRect { r.applying(pageToCanvas) }
    public func pageRect(fromCanvas r: PageRect) -> PageRect { r.applying(canvasToPage) }

    /// Page-space region visible in a viewport of the given size (in canvas points).
    public func visiblePageRect(viewportSize: PageSize) -> PageRect {
        pageRect(fromCanvas: PageRect(origin: .zero, size: viewportSize))
    }
}
